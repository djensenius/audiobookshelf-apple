import ABSCore
import Foundation
import Observation

/// Asks WidgetKit to reload a widget kind's timelines; `WidgetCenter` in the app, a fake in tests.
@MainActor
public protocol WidgetTimelineReloading: AnyObject {
    func reloadTimelines(ofKind kind: String)
}

/// Writes the Continue Listening widget's ``WidgetSnapshot`` to the App Group and reloads the
/// widget's timelines (#89).
///
/// - It writes and reloads at once when anything but the position changes: another item, play
///   or pause, a new chapter, title, author or cover. A position-only change waits until
///   ``minimumInterval`` has passed since the last write, so playback's ticks don't spend the
///   widget's reload budget; the next write carries the latest position.
/// - It clears the snapshot (deletes the file and reloads) when the user signs out, removes the
///   active account or the server rejects the session (``SessionParticipant``), and when the
///   snapshot's connection is removed while another one is active (``followRemovals(of:)``). A
///   switch keeps it: the widget still opens that item, asking to switch back.
/// - It ignores snapshots for any connection but the running session's, so a tick from the
///   ending session can't write the snapshot back after a sign-out cleared it.
@MainActor
public final class WidgetSnapshotWriter: SessionParticipant {
    /// The shortest time between two writes that only move the position.
    public let minimumInterval: TimeInterval
    private let fileURL: URL?
    private let reloader: any WidgetTimelineReloading
    private let now: () -> Date
    /// The running session's connection; `nil` when none runs.
    private var connectionID: UUID?
    /// The snapshot on disk, or `nil` when there is none.
    private var written: WidgetSnapshot?
    private var lastWrite: Date?
    private var following: Task<Void, Never>?
    private var removals: Task<Void, Never>?

    /// - Parameter fileURL: Where the snapshot goes (``WidgetSnapshot/defaultFileURL(appGroup:)``);
    ///   `nil` without an App Group, when nothing is written but the session is still followed.
    public init(
        fileURL: URL?, reloader: any WidgetTimelineReloading, minimumInterval: TimeInterval = 300,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.reloader = reloader
        self.minimumInterval = minimumInterval
        self.now = now
        written = fileURL.flatMap(WidgetSnapshot.read(from:))
    }

    isolated deinit {
        following?.cancel()
        removals?.cancel()
    }

    /// Records the current item's snapshot, subject to the rules above. `nil` (no item, as after
    /// the player closes) keeps the last one, so the widget still offers it.
    public func update(_ snapshot: WidgetSnapshot?) {
        guard let snapshot, snapshot.serverID == connectionID, snapshot != written else { return }
        if let written, let lastWrite, Self.positionOnly(written, snapshot),
            now().timeIntervalSince(lastWrite) < minimumInterval
        {
            return
        }
        write(snapshot)
    }

    /// Deletes the snapshot, so the widget shows its empty state.
    public func clear() {
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        written = nil
        lastWrite = nil
        reloader.reloadTimelines(ofKind: WidgetSnapshot.continueListeningKind)
    }

    /// Calls ``update(_:)`` with `player`'s ``PlayerViewModel/widgetSnapshot`` whenever it
    /// changes, until the writer is released or this is called again.
    public func follow(_ player: PlayerViewModel) {
        following?.cancel()
        following = Task { [weak self] in
            for await snapshot in Observations({ @MainActor in player.widgetSnapshot }) {
                guard !Task.isCancelled, let self else { return }
                self.update(snapshot)
            }
        }
    }

    /// Clears the snapshot once its connection leaves `savedConnections`, read with Observation
    /// (`AccountManager.connections`). Only a connection seen listed and then gone counts as
    /// removed, so a list that hasn't loaded yet (empty at launch) clears nothing. Follows until
    /// the writer is released or this is called again.
    public func followRemovals(of savedConnections: @escaping @MainActor @Sendable () -> Set<UUID>) {
        removals?.cancel()
        let initial = savedConnections()
        removals = Task { [weak self] in
            var known = initial
            for await saved in Observations({ @MainActor in savedConnections() }) {
                guard !Task.isCancelled, let self else { return }
                let removed = known.subtracting(saved)
                known = saved
                if let written = self.written, removed.contains(written.serverID) { self.clear() }
            }
        }
    }

    // MARK: - SessionParticipant

    public func sessionDidStart(_ context: SessionContext) async {
        connectionID = context.identity.connectionID
    }

    public func sessionWillEnd(_ reason: SessionEndReason) async {
        connectionID = nil
        switch reason {
        case .signOut, .removed, .expired: clear()
        case .switch: break
        }
    }

    // MARK: - Writing

    private func write(_ snapshot: WidgetSnapshot) {
        if let fileURL {
            do {
                try snapshot.write(to: fileURL)
            } catch {
                let reason = Log.redact(String(describing: error))
                Log.data.error("The widget snapshot couldn't be written: \(reason, privacy: .public)")
                return
            }
        }
        written = snapshot
        lastWrite = now()
        reloader.reloadTimelines(ofKind: WidgetSnapshot.continueListeningKind)
    }

    /// Whether `new` differs from `old` only in its position.
    private static func positionOnly(_ old: WidgetSnapshot, _ new: WidgetSnapshot) -> Bool {
        var moved = old
        moved.currentTime = new.currentTime
        return moved == new
    }
}

extension PlayerViewModel {
    /// The Continue Listening widget's snapshot of the current item; `nil` without one, or before
    /// its duration is known (a restored item before its media loads), so the widget keeps the
    /// last full snapshot rather than showing no progress.
    public var widgetSnapshot: WidgetSnapshot? {
        guard let key = playback.mediaKey, hasSession, playback.duration > 0 else { return nil }
        return WidgetSnapshot(
            serverID: key.serverConnectionID, itemID: key.libraryItemId, episodeID: key.episodeId, title: title,
            author: author, chapterTitle: chapterTitle, currentTime: playback.currentTime,
            duration: playback.duration, isPlaying: playback.isPlaybackRequested,
            coverKey: coverKey?.with(bucket: .small))
    }
}
