import ABSData
import Foundation
import Observation

/// Tells the system to fetch the App Shortcuts' entity parameters again (#87), so phrases such as
/// "Play <book> in Audiobookshelf" offer the signed-in account's Continue Listening.
///
/// It asks when an account's session starts, reconnects or ends (the suggestions are now another
/// account's, or none), and when the player starts an item other than the last one it started
/// (``follow(_:)``), which moves it to the front of Continue Listening. Never on the player's other
/// changes, such as each progress tick. Requests made while one waits (2 seconds by default) join
/// it, so they make one update.
///
/// `update` is the app's `AppShortcutsProvider.updateAppShortcutParameters()`; ABSAppModel never
/// imports AppIntents.
@MainActor
public final class ShortcutParametersRefresher: SessionParticipant {
    private let wait: @MainActor () async -> Void
    private let update: @MainActor () -> Void
    private var pending: Task<Void, Never>?
    private var following: Task<Void, Never>?

    /// - Parameters:
    ///   - wait: How long a request waits for others to join it; tests pass a gate.
    ///   - update: Updates the parameters.
    public init(
        wait: @escaping @MainActor () async -> Void = { try? await Task.sleep(for: .seconds(2)) },
        update: @escaping @MainActor () -> Void
    ) {
        self.wait = wait
        self.update = update
    }

    /// Updates the parameters after `wait`, once for every request made meanwhile.
    public func requestUpdate() {
        guard pending == nil else { return }
        pending = Task { [weak self, wait] in
            await wait()
            guard let self else { return }
            self.pending = nil
            self.update()
        }
    }

    /// Calls ``requestUpdate()`` whenever `player` starts playing an item other than the last one
    /// (``PlayerViewModel/spotlightRecord``), until the refresher is released or this is called
    /// again.
    public func follow(_ player: PlayerViewModel) {
        following?.cancel()
        following = Task { [weak self] in
            var last: MediaKey?
            for await key in Observations({ @MainActor in player.spotlightRecord?.key }) {
                guard !Task.isCancelled, let self else { return }
                guard let key, key != last else { continue }
                last = key
                self.requestUpdate()
            }
        }
    }

    // MARK: - SessionParticipant

    public func sessionDidStart(_ context: SessionContext) async {
        requestUpdate()
    }

    public func sessionDidReconnect(_ context: SessionContext) async {
        requestUpdate()
    }

    public func sessionWillEnd(_ reason: SessionEndReason) async {
        requestUpdate()
    }
}
