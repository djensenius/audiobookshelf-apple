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
    /// Records every scope's playback history; `nil` without a store.
    let history: (any PlaybackHistoryRecording)?

    /// The engine's time-update interval and the progress syncer's tick.
    static let tickInterval: TimeInterval = 0.5

    /// - Parameters:
    ///   - writer: The data environment's one ``LocalProgressStore``, which downloads link through
    ///     too (ADR 0003); without it (or without `accounts`) there is no participant, and the
    ///     player stays idle.
    ///   - deviceIdentifiers: The process-wide device ID for playback sessions (ADR 0007).
    ///   - library: Hears each session's playback progress, for its progress cache (#184).
    ///   - history: Records every scope's playback history, over the data environment's one
    ///     history store (#184).
    static func make(
        writer: LocalProgressStore?, accounts: AccountManager?, lifecycle: SessionLifecycle, settings: AppSettings,
        deviceIdentifiers: any DeviceIdentifying, library: LibraryParticipant? = nil,
        history: (any PlaybackHistoryRecording)? = nil
    ) -> AppPlayback {
        let current = CurrentPlayback()
        let player = PlayerViewModel(playback: current, settings: settings)
        guard let writer, let accounts else {
            return AppPlayback(current: current, player: player, writer: nil, participant: nil, history: nil)
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
            progressSink: { [weak library] update, context in
                library?.applyPlaybackProgress(update, sessionID: context.sessionID)
            },
            makeScope: { Self.makeScope(for: $0, settings: settings, policy: policy, history: history) })
        lifecycle.register(participant, stage: .progressSource)
        removesQueues(of: accounts, from: queueStore(settings: settings))
        return AppPlayback(current: current, player: player, writer: writer, participant: participant, history: history)
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

    /// Tells the running scope's auto-advance of each change to the library's progress (seeds,
    /// the socket, actions on other screens), so a finish elsewhere changes what plays next
    /// (#160). The cache and the participant both serve the active account.
    func follow(_ progress: ProgressCache) {
        progress.onChange = { [weak participant] in
            participant?.progressDidChange(libraryItemID: $0, episodeID: $1, kind: $2)
        }
    }

    /// One account session's scope, over an engine of its own. The connection's last-played record
    /// and queue are kept in the settings' defaults, under keys of their own.
    static func makeScope(
        for request: PlaybackScopeRequest, settings: AppSettings, policy: NetworkPolicy,
        history: (any PlaybackHistoryRecording)?
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
        return makeScope(
            for: request, settings: settings, policy: policy, engine: engine, interruptions: interruptions,
            history: history)
    }

    /// The scope over `engine`. An interruption also cancels a play the coordinator holds outside
    /// the engine (recovery's restart, the initial load, a pending streaming-policy check), so
    /// `interruptions` (the audio session's, on iOS) gets the coordinator; it holds it weakly, and
    /// the scope owns it.
    static func makeScope(
        for request: PlaybackScopeRequest, settings: AppSettings, policy: NetworkPolicy,
        engine: any AudioEngineProtocol, interruptions: AudioInterruptionHandler?,
        history: (any PlaybackHistoryRecording)? = nil
    ) -> PlaybackScope {
        let scopeConfiguration = Self.configuration(
            for: request, settings: settings, policy: policy, engine: engine, history: history)
        let scope = PlaybackScope.make(scopeConfiguration) {
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
    /// would treat the device as always online. The same path tells the auto-advance to prepare
    /// the next item again, which it starts under `backgroundActivity` (#160). The syncer
    /// records `history`.
    static func configuration(
        for request: PlaybackScopeRequest, settings: AppSettings, policy: NetworkPolicy,
        engine: any AudioEngineProtocol, history: (any PlaybackHistoryRecording)? = nil,
        backgroundActivity: any BackgroundActivity = makeBackgroundActivity()
    ) -> PlaybackScope.Configuration {
        var configuration = PlaybackScope.Configuration(
            connectionID: request.connectionID, client: request.client, features: request.features,
            deviceIdentifiers: request.deviceIdentifiers, writer: request.writer, settings: settings,
            policy: policy, engine: engine, tickInterval: tickInterval, backgroundActivity: backgroundActivity,
            lastPlayed: { PlaybackScope.lastPlayedStore(for: $0, defaults: settings.defaults) },
            queueStore: queueStore(settings: settings))
        configuration.networkPaths = SystemNetworkPathSource()
        configuration.history = history
        configuration.trackURLOverride = fixtureTrackURL
        return configuration
    }
}

/// Sets `\.playItem`, `\.bookmarkStore`, `\.sleepTimer` and `\.playbackQueue` from the running account session's
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
            .environment(\.playbackQueue, participant?.queue)
    }
}
