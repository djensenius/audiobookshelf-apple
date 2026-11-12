import ABSAPI
import ABSCore
import ABSData
import Foundation

/// What a ``PlaybackScope`` needs of the Now Playing bridge, so the scope stays extension-safe
/// (the bridge is unavailable in app extensions) and tests can record when it's invalidated.
@MainActor
public protocol NowPlayingHandle: AnyObject {
    /// Ends the Now Playing session for good.
    func invalidate()
    /// Asks the system to make this app's session the primary one, after a user-initiated play.
    func requestSystemPrimary() async
}

@available(iOSApplicationExtension, unavailable)
extension NowPlayingBridge: NowPlayingHandle {}

/// Playback for one account session (#183): its services, coordinator, attached progress syncer
/// and Now Playing bridge, built together and torn down together.
///
/// - **Start.** ``make(_:makeNowPlaying:)`` attaches the syncer before anything can play, so
///   every loaded session has a final-position reporter. ``start()`` restores the account's
///   last-played item, paused.
/// - **Reconnect.** ``reconnect(client:features:)`` swaps the client and features behind the
///   coordinator (``AccountPlaybackServices``); the scope and its playback carry on.
/// - **End.** ``retire(reason:)`` runs synchronously, before the session's teardown suspends: it
///   stops the coordinator for good and captures the final position.
///   ``finishRetirement(timeout:)`` then waits for the close, within a bound, and releases the
///   syncer, the bridge and the ``onRelease(_:)`` hooks, whatever the wait's outcome.
/// - **Transport.** The attached syncer syncs as it always does: pause, seek and periodic ticks
///   send `/sync`, and a successful sync drains pending progress. It is built with no network
///   path monitor (`paths: nil`), so nothing drains it on reconnect, and the scope never drains
///   or flushes it itself; launch, reconnect and background draining are #184's. Switch cleanup
///   keeps the services usable for the closes the switch allows; release never invalidates them.
@MainActor
public final class PlaybackScope {
    /// What ``make(_:makeNowPlaying:)`` builds a scope from.
    @MainActor
    public struct Configuration {
        public var connectionID: UUID
        /// The account's client; `nil` offline, which leaves the scope unable to stream.
        public var client: APIClient?
        /// The account's server features (saved ones offline); `nil` means no session can start.
        public var features: ServerFeatures?
        public var deviceIdentifiers: any DeviceIdentifying
        /// The data environment's one writer, shared by every scope: playback-position tokens are
        /// bound to it, so a retired scope's late write can't replace a newer scope's.
        public var writer: LocalProgressStore
        public var settings: any PlaybackSettingsProviding
        public var policy: any StreamingPolicyChecking
        public var engine: any AudioEngineProtocol
        /// The engine's time-update interval (`AudioEngine`'s `timeObserverInterval`).
        public var tickInterval: TimeInterval
        public var backgroundActivity: any BackgroundActivity
        /// The connection's last-played store. Each connection has its own, so one account's
        /// record survives another account playing.
        public var lastPlayed: @MainActor (UUID) -> any LastPlayedStoring

        public init(
            connectionID: UUID, client: APIClient?, features: ServerFeatures?,
            deviceIdentifiers: any DeviceIdentifying, writer: LocalProgressStore,
            settings: any PlaybackSettingsProviding, policy: any StreamingPolicyChecking,
            engine: any AudioEngineProtocol, tickInterval: TimeInterval,
            backgroundActivity: any BackgroundActivity = NoBackgroundActivity(),
            lastPlayed: @escaping @MainActor (UUID) -> any LastPlayedStoring = {
                PlaybackScope.lastPlayedStore(for: $0)
            }
        ) {
            self.connectionID = connectionID
            self.client = client
            self.features = features
            self.deviceIdentifiers = deviceIdentifiers
            self.writer = writer
            self.settings = settings
            self.policy = policy
            self.engine = engine
            self.tickInterval = tickInterval
            self.backgroundActivity = backgroundActivity
            self.lastPlayed = lastPlayed
        }
    }

    public let coordinator: PlaybackCoordinator
    /// Public so the network sync (#184) can drain and flush it.
    public let syncer: ProgressSyncer
    /// `nil` only for a scope built over other services (tests).
    public let services: AccountPlaybackServices?
    /// Called once, the first time the server rejects a session start as expired.
    public var onSessionRejected: (@MainActor () -> Void)?

    private let nowPlaying: any NowPlayingHandle
    private var observer: PlaybackObserverToken?
    private var releaseHooks: [@MainActor () -> Void] = []
    private var hasRaisedRejection = false
    private(set) var isReleased = false

    /// The `UserDefaults` key of a connection's last-played record.
    public static func lastPlayedKey(for connectionID: UUID) -> String {
        "\(UserDefaultsLastPlayedStore.defaultKey).\(connectionID.uuidString)"
    }

    /// The connection's own last-played store, under ``lastPlayedKey(for:)``.
    public static func lastPlayedStore(
        for connectionID: UUID, defaults: UserDefaults = AppSettings.sharedDefaults()
    ) -> UserDefaultsLastPlayedStore {
        UserDefaultsLastPlayedStore(defaults: defaults, key: lastPlayedKey(for: connectionID))
    }

    /// Builds the services, then the coordinator, then the syncer (attached before any play),
    /// then the Now Playing bridge, which the scope holds strongly.
    public static func make(
        _ configuration: Configuration, makeNowPlaying: (PlaybackCoordinator) -> any NowPlayingHandle
    ) -> PlaybackScope {
        let services = AccountPlaybackServices(
            serverConnectionID: configuration.connectionID, client: configuration.client,
            features: configuration.features, deviceIdentifiers: configuration.deviceIdentifiers)
        let coordinator = PlaybackCoordinator(
            engine: configuration.engine, sessions: services, progressStore: configuration.writer,
            settings: configuration.settings, policy: configuration.policy,
            lastPlayedStore: configuration.lastPlayed(configuration.connectionID),
            backgroundActivity: configuration.backgroundActivity)
        let syncer = ProgressSyncer(
            source: coordinator, service: services, store: configuration.writer,
            tickInterval: configuration.tickInterval, paths: nil)
        return PlaybackScope(
            coordinator: coordinator, syncer: syncer, services: services, nowPlaying: makeNowPlaying(coordinator))
    }

    /// Test seam: a scope over a coordinator and a syncer already attached to it.
    init(
        coordinator: PlaybackCoordinator, syncer: ProgressSyncer, services: AccountPlaybackServices?,
        nowPlaying: any NowPlayingHandle
    ) {
        self.coordinator = coordinator
        self.syncer = syncer
        self.services = services
        self.nowPlaying = nowPlaying
        observer = coordinator.addObserver { [weak self] event in
            guard case .failed(.sessionStartFailed(.sessionExpired)) = event else { return }
            self?.sessionRejected()
        }
    }

    private func sessionRejected() {
        guard !hasRaisedRejection, !isReleased else { return }
        hasRaisedRejection = true
        onSessionRejected?()
    }

    // MARK: Commands

    /// Restores the connection's last-played item, paused. Returns whether one was restored.
    @discardableResult
    public func start() -> Bool {
        coordinator.restoreLastPlayed()
    }

    /// Plays an item for the user, then asks for the system's primary Now Playing session if
    /// playback started without an error.
    public func play(itemID: String, episodeID: String?, startTime: Double?) async {
        await coordinator.play(itemID: itemID, episodeID: episodeID, startTime: startTime)
        guard !coordinator.isRetired, coordinator.phase != .idle, coordinator.error == nil else { return }
        await nowPlaying.requestSystemPrimary()
    }

    /// Swaps the account's client and features after a reconnect, without rebuilding anything.
    public func reconnect(client: APIClient?, features: ServerFeatures?) {
        services?.update(client: client, features: features)
    }

    /// Saves the loaded item as the last-played record. Local only.
    public func saveLocally() {
        coordinator.saveLastPlayed()
    }

    /// Adds work to run when the scope is released, after the bridge is invalidated (the sleep
    /// timer's detach, #185). Runs at once if the scope was already released.
    public func onRelease(_ body: @escaping @MainActor () -> Void) {
        guard !isReleased else { return body() }
        releaseHooks.append(body)
    }

    /// Stops the coordinator for good, synchronously: call it before the teardown first suspends.
    /// It captures the final position; expiry, sign-out and removal also drop the client, so
    /// nothing reaches the server after. Pass an account-ending reason, never `.user`.
    public func retire(reason: PlaybackStopReason) {
        assert(reason != .user, "A scope retires only for an account-ending reason")
        coordinator.stop(reason: reason)
        switch reason {
        case .expired, .signOut, .accountRemoved: services?.invalidate()
        case .user, .accountSwitch: break
        }
    }

    /// Waits, at most `timeout`, for the closes ``retire(reason:)`` captured, then releases the
    /// scope whatever the outcome: detaches the syncer, invalidates the bridge and runs the
    /// ``onRelease(_:)`` hooks. Neither a timeout nor cancellation cancels the captured local
    /// write; the syncer keeps it going after detaching.
    /// - Returns: The close outcome, or why it isn't durable (``PlaybackCloseError``, or
    ///   `CancellationError` when the caller was cancelled).
    public func finishRetirement(
        timeout: Duration = PlaybackCoordinator.closeWaitTimeout
    ) async -> Result<PlaybackCloseOutcome, any Error> {
        let result: Result<PlaybackCloseOutcome, any Error>
        do {
            result = .success(try await coordinator.waitForClose(timeout: timeout))
        } catch {
            result = .failure(error)
        }
        release()
        return result
    }

    private func release() {
        guard !isReleased else { return }
        isReleased = true
        // Only the syncer's hooks on the coordinator are cut here, after the close wait. A library
        // progress sink (#184) must instead be cut off in `retire(reason:)`: the library's
        // progress cache has no generation check, and the next account can start before this runs.
        syncer.detach()
        if let observer { coordinator.removeObserver(observer) }
        observer = nil
        onSessionRejected = nil
        nowPlaying.invalidate()
        let hooks = releaseHooks
        releaseHooks = []
        for hook in hooks { hook() }
    }
}
