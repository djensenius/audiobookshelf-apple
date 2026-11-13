import ABSAppModel
import ABSCore
import ABSData

/// The realtime socket (#59), built once by ``AppEnvironment``: one ``RealtimeBridge`` that every
/// account session starts and stops, registered at ``SessionStage/progressSource`` after playback,
/// so it starts once the player's scope is bound and stops before the scope retires.
///
/// The bridge writes the library's progress cache, the signed-in user, the session's bookmarks and
/// socket progress for local rows (``RealtimeBridge/route(library:accounts:bookmarks:playback:localProgress:)``),
/// and reconnects at once when the network path changes.
@MainActor
struct AppRealtime {
    let bridge: RealtimeBridge
    /// Kept for the environment's lifetime: its path stream ends, and with it the bridge's
    /// following, when it's released.
    private let monitor: NetworkMonitor

    static func make(
        library: LibraryParticipant, accounts: AccountManager, playback: AppPlayback,
        localProgress: LocalProgressStore?, lifecycle: SessionLifecycle
    ) -> AppRealtime {
        let bridge = RealtimeBridge(progress: library.store.progress)
        bridge.route(
            library: library.store, accounts: accounts,
            bookmarks: { [weak participant = playback.participant] in participant?.bookmarks },
            playback: playback.current, localProgress: localProgress)
        lifecycle.register(bridge, stage: .progressSource)
        let monitor = NetworkMonitor()
        monitor.start()
        let paths = monitor.paths()
        Task { await bridge.follow(paths) }
        return AppRealtime(bridge: bridge, monitor: monitor)
    }
}
