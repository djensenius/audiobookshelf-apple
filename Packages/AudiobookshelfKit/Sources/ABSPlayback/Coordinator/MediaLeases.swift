import ABSData
import Foundation

/// Per-media exclusion between playback and the item actions that change progress (#368). One
/// instance is shared by every scope's coordinator and the item actions, as the local progress
/// writer is, so a key's holders see each other across windows, scopes and accounts.
///
/// - A coordinator holds a ``Holder/closingSession`` lease on each session it closes until the
///   close's transport (`/close` with its final report) and its captured local position write
///   settle: until then that work can recreate discarded progress or restore the old position.
/// - A progress action waits for those to settle, then holds a ``Holder/progressAction`` lease
///   through its server request and local sync, and a session start of the same media waits for
///   it, so it never starts from the position the action replaces.
@MainActor
public final class MediaLeases {
    public enum Holder: Sendable, Hashable {
        case closingSession
        case progressAction
    }

    private var holds: [MediaKey: [UUID: Holder]] = [:]
    private var waiters: [MediaKey: [UUID: CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    /// Holds `key` for `holder` until the lease's ``MediaLease/release()``.
    public func acquire(_ key: MediaKey, for holder: Holder) -> MediaLease {
        let id = UUID()
        holds[key, default: [:]][id] = holder
        return MediaLease { [weak self] in self?.release(id, of: key) }
    }

    /// Waits until no `other` lease holds `key`, then holds it for `holder`, in the same turn.
    public func acquire(_ key: MediaKey, for holder: Holder, after other: Holder) async -> MediaLease {
        await waitUntilFree(key, of: other)
        return acquire(key, for: holder)
    }

    public func isHeld(_ key: MediaKey, by holder: Holder) -> Bool {
        holds[key]?.values.contains(holder) ?? false
    }

    /// Returns once no `holder` lease holds `key`, or once the waiting task is cancelled.
    public func waitUntilFree(_ key: MediaKey, of holder: Holder) async {
        while isHeld(key, by: holder), !Task.isCancelled {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume()
                    } else {
                        waiters[key, default: [:]][id] = continuation
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.waiters[key]?.removeValue(forKey: id)?.resume() }
            }
        }
    }

    private func release(_ id: UUID, of key: MediaKey) {
        guard holds[key]?.removeValue(forKey: id) != nil else { return }
        if holds[key]?.isEmpty == true { holds[key] = nil }
        // Each waiter checks its own holder again.
        let resumed = waiters.removeValue(forKey: key) ?? [:]
        for continuation in resumed.values { continuation.resume() }
    }
}

/// A hold on a media key (``MediaLeases``). Release it once its work settled; releasing again does
/// nothing.
@MainActor
public final class MediaLease {
    private var onRelease: (@MainActor () -> Void)?

    init(onRelease: @escaping @MainActor () -> Void) {
        self.onRelease = onRelease
    }

    public func release() {
        let onRelease = onRelease
        self.onRelease = nil
        onRelease?()
    }
}
