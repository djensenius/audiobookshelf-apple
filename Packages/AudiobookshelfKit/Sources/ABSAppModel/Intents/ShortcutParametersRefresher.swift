import ABSData
import Foundation
import Observation

/// Tells the system to fetch the App Shortcuts' entity parameters again (#87), so phrases such as
/// "Play <book> in Audiobookshelf" offer the signed-in account's Continue Listening.
///
/// - When an account's session starts or reconnects, and once one's teardown is over
///   (``followEndedSessions(of:)``, `SessionLifecycle.endedSessions`), the suggestions are
///   another account's or none: it updates after `sessionWait` (2 seconds by default), and session
///   requests made meanwhile join it. Not from ``sessionWillEnd(_:)``: the lifecycle ends the
///   participants one at a time, the library possibly seconds later, and an update before the
///   library is cleared would publish the ended account's items again.
/// - When the player starts an item other than the last one it started (``follow(_:)``), the
///   server moves it to the front of Continue Listening, but only once its progress is synced
///   (`ProgressSyncer.syncInterval`, 15 seconds, after it starts). With no signal for that sync,
///   it updates after `itemWait` (20 seconds by default), so the suggestions are read after it.
///   Another item starting meanwhile starts the wait over, for its own sync. Never on the
///   player's other changes, such as each progress tick.
/// - A session that starts or ends drops a waiting item request: the session's update covers it.
///
/// `update` is the app's `AppShortcutsProvider.updateAppShortcutParameters()`; ABSAppModel never
/// imports AppIntents.
@MainActor
public final class ShortcutParametersRefresher: SessionParticipant {
    /// How long an item request waits by default: longer than `ProgressSyncer.syncInterval`.
    public static let itemDelay: Duration = .seconds(20)

    private let sessionWait: @MainActor () async -> Void
    private let itemWait: @MainActor () async -> Void
    private let update: @MainActor () -> Void
    private var pendingSession: Task<Void, Never>?
    private var pendingItem: Task<Void, Never>?
    private var following: Task<Void, Never>?
    private var endings: Task<Void, Never>?

    /// - Parameters:
    ///   - sessionWait: How long a session request waits for others to join it; tests pass a gate.
    ///   - itemWait: How long an item request waits, for its progress to reach the server; tests
    ///     pass a gate.
    ///   - update: Updates the parameters.
    public init(
        sessionWait: @escaping @MainActor () async -> Void = { try? await Task.sleep(for: .seconds(2)) },
        itemWait: @escaping @MainActor () async -> Void = {
            try? await Task.sleep(for: ShortcutParametersRefresher.itemDelay)
        },
        update: @escaping @MainActor () -> Void
    ) {
        self.sessionWait = sessionWait
        self.itemWait = itemWait
        self.update = update
    }

    isolated deinit {
        following?.cancel()
        endings?.cancel()
        pendingSession?.cancel()
        pendingItem?.cancel()
    }

    /// Updates the parameters after `sessionWait`, once for every session request made meanwhile.
    public func requestUpdate() {
        schedule(\.pendingSession, after: sessionWait)
    }

    /// Updates the parameters after `itemWait` from now: a waiting item request, for an earlier
    /// item, starts over, so the update comes after this item's first sync.
    func requestItemUpdate() {
        dropItemRequest()
        schedule(\.pendingItem, after: itemWait)
    }

    /// Calls ``requestItemUpdate()`` whenever `player` starts playing an item other than the last
    /// one (``PlayerViewModel/spotlightRecord``), until the refresher is released or this is called
    /// again.
    public func follow(_ player: PlayerViewModel) {
        following?.cancel()
        following = Task { [weak self] in
            var last: MediaKey?
            for await key in Observations({ @MainActor in player.spotlightRecord?.key }) {
                guard !Task.isCancelled, let self else { return }
                guard let key, key != last else { continue }
                last = key
                self.requestItemUpdate()
            }
        }
    }

    /// Calls ``requestUpdate()`` each time `ended` (`SessionLifecycle.endedSessions`) counts
    /// another session's finished teardown, until the refresher is released or this is called
    /// again.
    public func followEndedSessions(of ended: @escaping @MainActor @Sendable () -> Int) {
        endings?.cancel()
        let initial = ended()
        endings = Task { [weak self] in
            var seen = initial
            for await count in Observations({ @MainActor in ended() }) {
                guard !Task.isCancelled, let self else { return }
                guard count != seen else { continue }
                seen = count
                self.requestUpdate()
            }
        }
    }

    /// Runs `update` after `wait` unless `slot` already waits. A cancelled wait updates nothing;
    /// whoever cancels it empties `slot`.
    private func schedule(
        _ slot: ReferenceWritableKeyPath<ShortcutParametersRefresher, Task<Void, Never>?>,
        after wait: @escaping @MainActor () async -> Void
    ) {
        guard self[keyPath: slot] == nil else { return }
        self[keyPath: slot] = Task { [weak self] in
            await wait()
            guard !Task.isCancelled, let self else { return }
            self[keyPath: slot] = nil
            self.update()
        }
    }

    /// Cancels a waiting item request.
    private func dropItemRequest() {
        pendingItem?.cancel()
        pendingItem = nil
    }

    // MARK: - SessionParticipant

    public func sessionDidStart(_ context: SessionContext) async {
        dropItemRequest()
        requestUpdate()
    }

    public func sessionDidReconnect(_ context: SessionContext) async {
        requestUpdate()
    }

    /// Drops a waiting item request only: the update waits for the whole teardown
    /// (``followEndedSessions(of:)``).
    public func sessionWillEnd(_ reason: SessionEndReason) async {
        dropItemRequest()
    }
}
