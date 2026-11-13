import ABSAppModel
import ABSCore
import ABSData
import ABSPlayback
import Foundation
import SwiftUI

/// Playback (#183), built once by ``AppEnvironment``: the one ``PlayerViewModel`` every window and
/// CarPlay share, and the session participant that gives each signed-in account a
/// ``PlaybackScope`` of its own.
///
/// The participant re-binds ``current`` to each session's coordinator, and ``player`` reads it, so
/// the player is idle between sessions and without a store. Every scope writes progress through
/// the one ``writer``: progress tokens are bound to it, so a retired scope's late write can't
/// replace a newer position.
@MainActor
struct AppPlayback {
    let current: CurrentPlayback
    let player: PlayerViewModel
    /// The data environment's one local progress writer; `nil` without a store.
    let writer: LocalProgressStore?
    /// Registered with the lifecycle at ``SessionStage/progressSource``; `nil` without a store.
    let participant: PlaybackSessionParticipant?

    /// The engine's time-update interval and the progress syncer's tick.
    static let tickInterval: TimeInterval = 0.5

    /// - Parameters:
    ///   - writer: The data environment's one ``LocalProgressStore``, which downloads link through
    ///     too (ADR 0003); without it (or without `accounts`) there is no participant, and the
    ///     player stays idle.
    ///   - deviceIdentifiers: The process-wide device ID for playback sessions (ADR 0007).
    static func make(
        writer: LocalProgressStore?, accounts: AccountManager?, lifecycle: SessionLifecycle, settings: AppSettings,
        deviceIdentifiers: any DeviceIdentifying
    ) -> AppPlayback {
        let current = CurrentPlayback()
        let player = PlayerViewModel(playback: current, settings: settings)
        guard let writer, let accounts else {
            return AppPlayback(current: current, player: player, writer: nil, participant: nil)
        }
        let monitor = NetworkMonitor()
        monitor.start()
        let policy = NetworkPolicy(monitor: monitor, settings: settings)
        let participant = PlaybackSessionParticipant(
            current: current, writer: writer, deviceIdentifiers: deviceIdentifiers,
            // Never made up: the active account's features, which offline are the saved ones, if any.
            features: { [weak accounts] identity in
                guard let accounts, accounts.activeConnection?.id == identity.connectionID else { return nil }
                return accounts.features
            },
            requestSignOut: { [weak lifecycle] in lifecycle?.requestSignOut(of: $0) },
            // Each session's bookmarks are unavailable while the session is offline.
            makeBookmarks: { [weak lifecycle] in
                BookmarkStore(isOffline: {
                    guard let gate = lifecycle?.gate, case .ready(_, let isOffline) = gate else { return false }
                    return isOffline
                })
            },
            makeScope: { Self.makeScope(for: $0, settings: settings, policy: policy) })
        lifecycle.register(participant, stage: .progressSource)
        return AppPlayback(current: current, player: player, writer: writer, participant: participant)
    }

    /// Hands the playback intents (widgets, controls, Shortcuts, Siri) to ``current``, so they
    /// share the player with the app's UI and CarPlay. Once per process. Each command first awaits
    /// `lifecycle.start()`: an intent can launch the app without a scene to start it.
    /// The play-item intents and entity queries (#87) use the same handler, with `library`'s
    /// account and the participant's play action.
    func registerIntents(settings: AppSettings, lifecycle: SessionLifecycle, library: LibraryStore?) {
        let handler = PlaybackIntentHandler(
            playback: current, settings: settings,
            sleepTimer: { [weak participant] in participant?.sleepTimer },
            ready: { [weak lifecycle] in await lifecycle?.start() },
            playItem: { [weak participant] in participant?.playItem },
            library: { [weak library] in library })
        PlaybackIntentRouter.handler = handler
        PlayableEntityRouter.handler = handler
    }

    /// One account session's scope, over an engine of its own. The connection's last-played record
    /// and queue are kept in the settings' defaults, under keys of their own.
    private static func makeScope(
        for request: PlaybackScopeRequest, settings: AppSettings, policy: NetworkPolicy
    ) -> PlaybackScope {
        #if os(iOS)
            let engine = AudioEngine(timeObserverInterval: tickInterval)
            // The engine holds the controller, which holds the engine weakly.
            let audioSession = AudioSessionController(engine: engine)
            engine.audioSession = audioSession
            let interruptions: AudioInterruptionHandler? = audioSession.interruptionHandler
        #else
            let engine = AudioEngine(audioSession: nil, timeObserverInterval: tickInterval)
            let interruptions: AudioInterruptionHandler? = nil
        #endif
        return makeScope(for: request, settings: settings, policy: policy, engine: engine, interruptions: interruptions)
    }

    /// The scope over `engine`. An interruption also cancels a play the coordinator holds outside
    /// the engine (recovery's restart, the initial load, a pending streaming-policy check), so
    /// `interruptions` (the audio session's, on iOS) gets the coordinator; it holds it weakly, and
    /// the scope owns it.
    static func makeScope(
        for request: PlaybackScopeRequest, settings: AppSettings, policy: NetworkPolicy,
        engine: any AudioEngineProtocol, interruptions: AudioInterruptionHandler?
    ) -> PlaybackScope {
        let scope = PlaybackScope.make(configuration(for: request, settings: settings, policy: policy, engine: engine))
        {
            coordinator in
            // No artwork or App Intents entities yet.
            NowPlayingBridge(
                coordinator: coordinator, settings: settings, coverProvider: { _ in nil },
                entityIdentifiers: { _ in [] })
        }
        interruptions?.heldPlayIntent = scope.coordinator
        return scope
    }

    /// The scope's configuration. Recovery waits on the system's network path; without one it
    /// would treat the device as always online.
    static func configuration(
        for request: PlaybackScopeRequest, settings: AppSettings, policy: NetworkPolicy,
        engine: any AudioEngineProtocol
    ) -> PlaybackScope.Configuration {
        var configuration = PlaybackScope.Configuration(
            connectionID: request.connectionID, client: request.client, features: request.features,
            deviceIdentifiers: request.deviceIdentifiers, writer: request.writer, settings: settings,
            policy: policy, engine: engine, tickInterval: tickInterval,
            lastPlayed: { PlaybackScope.lastPlayedStore(for: $0, defaults: settings.defaults) },
            queueStore: UserDefaultsPlaybackQueueStore(defaults: settings.defaults))
        configuration.networkPaths = SystemNetworkPathSource()
        return configuration
    }
}

/// Sets `\.playItem`, `\.bookmarkStore` and `\.sleepTimer` from the running account session's
/// playback, each `nil` between sessions; the sleep timer is `nil` until the scope has one (#185).
/// A view modifier, so it follows the participant as each session starts and ends. The signed-in
/// shell passes the participant only while it serves the shell's account
/// (``RootView/playback(_:accounts:for:)``).
struct PlaybackEnvironment: ViewModifier {
    let participant: PlaybackSessionParticipant?

    func body(content: Content) -> some View {
        content
            .environment(\.playItem, participant?.playItem)
            .environment(\.bookmarkStore, participant?.bookmarks)
            .environment(\.sleepTimer, participant?.sleepTimer)
    }
}
