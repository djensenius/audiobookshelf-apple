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
    /// Asks the system to make this app's session the primary one, after a user-initiated play,
    /// once playback is active. Publishes the current state first, so the application-primary
    /// activation it waits for has started, and asks only if `isStillWanted` holds once that
    /// activation finishes.
    func claimSystemPrimary(while isStillWanted: @MainActor () -> Bool) async
}

@available(iOSApplicationExtension, unavailable)
extension NowPlayingBridge: NowPlayingHandle {
    public func claimSystemPrimary(while isStillWanted: @MainActor () -> Bool) async {
        // The bridge otherwise republishes on a later main-actor turn, and a request made before
        // the application-primary activation started would do nothing.
        refresh()
        await requestSystemPrimary(while: isStillWanted)
    }
}

/// Where local playback has reached, for the library's progress cache (#184).
public struct PlaybackProgressUpdate: Sendable, Equatable {
    public var key: MediaKey
    public var currentTime: Double
    /// `0` when not known yet.
    public var duration: Double
    /// When playback was there.
    public var date: Date

    public init(key: MediaKey, currentTime: Double, duration: Double, date: Date) {
        self.key = key
        self.currentTime = currentTime
        self.duration = duration
        self.date = date
    }
}

/// Playback for one account session (#183): its services, coordinator, attached progress syncer
/// and Now Playing bridge, built together and torn down together.
///
/// - **Start.** ``make(_:makeNowPlaying:)`` attaches the syncer before anything can play, so
///   every loaded session has a final-position reporter, and the auto-advance over the
///   connection's ``queue``. ``start()`` restores the account's last-played item, paused.
/// - **Queue.** The scope owns its connection's one live ``PlaybackQueue`` (loaded from the
///   store when the scope is made) and the ``PlaybackQueueAdvancer`` that plays it.
///   ``editQueue(_:)`` changes it until retirement, which detaches the advancer and freezes the
///   queue, so a retired scope's queue never changes again, even through a reference kept from
///   an edit, and the connection's next scope loads what it saved.
/// - **Reconnect.** ``reconnect(client:features:)`` swaps the client and features behind the
///   coordinator (``AccountPlaybackServices``); the scope and its playback carry on.
/// - **Sleep timer.** The configured ``sleepTimer`` (#185) is attached to the coordinator, which
///   asks it before playback starts and tells it of item changes and seeks, until the scope
///   retires, which detaches and cancels it. The release detaches it again, as a backstop.
/// - **End.** ``retire(reason:)`` runs synchronously, before the session's teardown suspends: it
///   stops the coordinator for good and captures the final position.
///   ``finishRetirement(timeout:)`` then waits for the close, within a bound, and releases the
///   syncer, the bridge and the ``onRelease(_:)`` hooks, whatever the wait's outcome.
/// - **Transport** (#184). The attached syncer syncs as it always does: pause, seek and periodic
///   ticks send `/sync`, and a successful sync drains pending progress. It follows the configured
///   network path, so it drains whenever the device comes back online. ``syncWithServer(isFirstSync:)``
///   drains it and then uploads the connection's pending local sessions (``LocalSessionUploader``),
///   at the session's start and on each reconnect, online: the session's, and the network path's,
///   which the scope follows too, so uploads a failed sync left are retried even when the account
///   and its client stay the same. ``flush()`` reports and drains for the
///   lifecycle's bounded flush, on background and before sign-out or a switch. A `/sync` the
///   server answers with 404 for the loaded session replaces that session at the same position
///   (``PlaybackCoordinator/replaceGoneSession(_:)``). Switch cleanup keeps the services usable
///   for the closes the switch allows; release never invalidates them.
/// - **Library progress.** ``onProgress`` hears where playback is (pauses, seeks, the end, closes,
///   and ticks at most every ``progressInterval`` of media time), until retirement cuts it off.
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
        /// Where the connection's play queue is saved, under a key of its own.
        public var queueStore: any PlaybackQueueStoring
        /// Builds the sleep timer over the scope's coordinator; the app passes
        /// `{ SleepTimerAttachment(coordinator: $0, settings: settings) }` with the settings every
        /// scene shares. `nil` leaves the scope without one.
        public var makeSleepTimer: (@MainActor (PlaybackCoordinator) -> SleepTimerAttachment)?
        /// The network path recovery waits on, and the syncer drains on when it comes back online,
        /// as the scope runs ``PlaybackScope/syncWithServer(isFirstSync:)`` then; the app sets
        /// `SystemNetworkPathSource()`. `nil` treats it as always satisfied, and leaves reconnect
        /// syncing to the session's reconnects.
        public var networkPaths: (any NetworkPathSource)?
        /// Records the scope's playback history (``ProgressSyncer``'s `history`); the app sets a
        /// `PlaybackHistoryRecorder` over its one history store. `nil` records none.
        public var history: (any PlaybackHistoryRecording)?
        /// Rewrites each stream URL the scope's services resolve, before the engine loads it. The
        /// app sets it only for a UI-test fixture launch, whose tracks play from a bundled file
        /// (#46). `nil` plays the server's URLs.
        public var trackURLOverride: (@Sendable (URL) -> URL)?

        public init(
            connectionID: UUID, client: APIClient?, features: ServerFeatures?,
            deviceIdentifiers: any DeviceIdentifying, writer: LocalProgressStore,
            settings: any PlaybackSettingsProviding, policy: any StreamingPolicyChecking,
            engine: any AudioEngineProtocol, tickInterval: TimeInterval,
            backgroundActivity: any BackgroundActivity = NoBackgroundActivity(),
            lastPlayed: @escaping @MainActor (UUID) -> any LastPlayedStoring = {
                PlaybackScope.lastPlayedStore(for: $0)
            },
            queueStore: (any PlaybackQueueStoring)? = nil,
            makeSleepTimer: (@MainActor (PlaybackCoordinator) -> SleepTimerAttachment)? = nil
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
            self.queueStore = queueStore ?? UserDefaultsPlaybackQueueStore()
            self.makeSleepTimer = makeSleepTimer
        }
    }

    public let coordinator: PlaybackCoordinator
    /// Public so the network sync (#184) can drain and flush it.
    public let syncer: ProgressSyncer
    /// `nil` only for a scope built over other services (tests).
    public let services: AccountPlaybackServices?
    /// Called once, the first time the server rejects a session start as expired.
    public var onSessionRejected: (@MainActor () -> Void)?
    /// Hears where playback is, for the library's progress cache, until ``retire(reason:)``.
    public var onProgress: (@MainActor (PlaybackProgressUpdate) -> Void)?
    /// The media time between two ticks ``onProgress`` hears.
    public static let progressInterval: Double = 10

    /// Uploads the connection's pending local sessions; `nil` only for a scope built without one
    /// (tests).
    let uploader: LocalSessionUploader?
    /// Auto-advance over the connection's queue, attached to the coordinator until
    /// ``retire(reason:)``. `nil` only for a scope built without a queue (tests).
    let advancer: PlaybackQueueAdvancer?
    /// The sleep timer, for the player; `nil` for a scope built without one. Its attachment is
    /// detached, cancelling it, when the scope retires, and again when it's released.
    public var sleepTimer: SleepTimer? { sleepTimerAttachment?.timer }
    private let sleepTimerAttachment: SleepTimerAttachment?
    private let nowPlaying: any NowPlayingHandle
    private var isRetired = false
    private var observer: PlaybackObserverToken?
    private var releaseHooks: [@MainActor () -> Void] = []
    private var hasRaisedRejection = false
    private(set) var isReleased = false
    /// A user play's system-primary claim, waiting for playback to become active.
    private var pendingPrimaryClaim: Task<Void, Never>?
    /// The latest ``syncWithServer(isFirstSync:)``; each waits for the one before it.
    private var serverSync: Task<Void, Never>?
    /// The `isFirstSync` of the server sync that waits to start; `nil` when none waits.
    private var queuedServerSync: Bool?
    /// Follows the network path, for ``syncWithServer(isFirstSync:)`` on reconnects, until
    /// ``retire(reason:)``.
    private(set) var pathTask: Task<Void, Never>?
    /// Hears each path the scope handled, and whether it asked for a server sync (tests).
    var pathHandled: (@MainActor (NetworkPath, Bool) -> Void)?
    /// The last update ``onProgress`` heard, to space out ticks.
    private var lastProgress: PlaybackProgressUpdate?
    /// The latest replacement of a session the server no longer has (tests wait for it).
    private(set) var sessionReplacement: Task<Void, Never>?

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

    /// Builds the services, then the coordinator, then the syncer (attached before any play,
    /// following the configured network path and recording the configured history), then the
    /// sleep timer, if configured, then the Now Playing bridge, which the scope holds strongly,
    /// and the queue's advancer, whose podcast fallback reads episodes through the services'
    /// current client. The local-session uploader sends through the services too, so it follows
    /// reconnects.
    public static func make(
        _ configuration: Configuration, makeNowPlaying: (PlaybackCoordinator) -> any NowPlayingHandle
    ) -> PlaybackScope {
        let services = AccountPlaybackServices(
            serverConnectionID: configuration.connectionID, client: configuration.client,
            features: configuration.features, deviceIdentifiers: configuration.deviceIdentifiers,
            trackURLOverride: configuration.trackURLOverride)
        let coordinator = PlaybackCoordinator(
            engine: configuration.engine, sessions: services, progressStore: configuration.writer,
            settings: configuration.settings, policy: configuration.policy,
            lastPlayedStore: configuration.lastPlayed(configuration.connectionID),
            backgroundActivity: configuration.backgroundActivity, networkPaths: configuration.networkPaths)
        let syncer = ProgressSyncer(
            source: coordinator, service: services, store: configuration.writer,
            tickInterval: configuration.tickInterval, paths: configuration.networkPaths, history: configuration.history)
        let sleepTimer = configuration.makeSleepTimer?(coordinator)
        let queue = PlaybackQueue(serverConnectionID: configuration.connectionID, store: configuration.queueStore)
        let episodes = APIPodcastEpisodeSource(
            serverConnectionID: configuration.connectionID, localProgress: configuration.writer,
            fetchItem: { try await services.client().send(ItemEndpoints.item(id: $0)) },
            fetchFinished: { try await services.client().send(UserEndpoints.me()) })
        let uploader = LocalSessionUploader(
            serverConnectionID: configuration.connectionID, store: configuration.writer, service: services,
            deviceIdentifiers: configuration.deviceIdentifiers)
        return PlaybackScope(
            coordinator: coordinator, syncer: syncer, services: services, nowPlaying: makeNowPlaying(coordinator),
            queue: queue, episodes: episodes, sleepTimer: sleepTimer, uploader: uploader,
            paths: configuration.networkPaths)
    }

    /// Test seam: a scope over a coordinator and a syncer already attached to it, an advancer
    /// over `queue`, when one is given, attached to the coordinator, `sleepTimer`, detached
    /// when the scope retires, and again when it's released, `uploader`, sending through any
    /// services, and `paths`, followed for reconnects.
    init(
        coordinator: PlaybackCoordinator, syncer: ProgressSyncer, services: AccountPlaybackServices?,
        nowPlaying: any NowPlayingHandle, queue: PlaybackQueue? = nil, episodes: (any PodcastEpisodeSource)? = nil,
        sleepTimer: SleepTimerAttachment? = nil, uploader: LocalSessionUploader? = nil,
        paths: (any NetworkPathSource)? = nil
    ) {
        self.coordinator = coordinator
        self.syncer = syncer
        self.services = services
        self.nowPlaying = nowPlaying
        self.uploader = uploader
        sleepTimerAttachment = sleepTimer
        advancer = queue.map { PlaybackQueueAdvancer(queue: $0, episodes: episodes) }
        advancer?.attach(to: coordinator)
        observer = coordinator.addObserver { [weak self] event in self?.handle(event) }
        services?.setSessionGoneHandler { [weak self] sessionID in
            Task { @MainActor [weak self] in self?.sessionGone(sessionID) }
        }
        if let sleepTimer { onRelease { sleepTimer.detach() } }
        if let paths { watch(paths.paths()) }
    }

    private func handle(_ event: PlaybackCoordinatorEvent) {
        switch event {
        case .failed(.sessionStartFailed(.sessionExpired)): sessionRejected()
        case .tick(let time): reportProgress(at: time, spaced: true)
        case .paused(let time), .didSeek(let time): reportProgress(at: time)
        case .ended: reportProgress(at: coordinator.duration)
        case .sessionWillClose(let closing) where closing.wasLoaded:
            report(
                PlaybackProgressUpdate(
                    key: closing.key, currentTime: closing.currentTime, duration: closing.duration, date: Date()))
        default: break
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

    /// Plays an item for the user, then claims the system's primary Now Playing session
    /// (``claimSystemPrimaryOnceActive()``).
    public func play(itemID: String, episodeID: String?, startTime: Double?) async {
        await coordinator.play(itemID: itemID, episodeID: episodeID, startTime: startTime)
        await claimSystemPrimaryOnceActive()
    }

    /// Resumes for the user (the player's play button, which may restart a restored item), then
    /// claims the system's primary Now Playing session (``claimSystemPrimaryOnceActive()``).
    /// Remote commands (Lock Screen, headphones) resume the coordinator through the bridge
    /// instead, and don't claim it.
    public func resume(rewindingBy seconds: Double?) async {
        await coordinator.resume(rewindingBy: seconds)
        await claimSystemPrimaryOnceActive()
    }

    /// Streams the play the user confirmed on a metered network
    /// (``PlaybackCoordinator/confirmMeteredStreaming()``), then claims the system's primary Now
    /// Playing session, as a user play does.
    public func confirmMeteredStreaming() async {
        await coordinator.confirmMeteredStreaming()
        await claimSystemPrimaryOnceActive()
    }

    /// After a user play or resume: claims the system's primary session if playback is requested
    /// without an error (a pause during the play's seek leaves none to claim). Playback may
    /// still be on its way (an initial seek or a load before the audio session activates); the
    /// claim then waits until the bridge publishes it playing. Until the system-primary request
    /// is made (after the application-primary activation), the claim stays revocable: a pause,
    /// an error, retirement, release or a newer user play drops it. Returns once a claim that
    /// could be made at once was, or once a later one is pending.
    private func claimSystemPrimaryOnceActive() async {
        revokePrimaryClaim()
        let initial = PrimaryClaim(of: coordinator, isReleased: isReleased)
        guard initial != .drop else { return }
        let coordinator = coordinator
        let nowPlaying = nowPlaying
        let claim = Task { [weak self] in
            if initial == .wait {
                let states = Observations { @MainActor in PrimaryClaim(of: coordinator, isReleased: false) }
                var state = PrimaryClaim.wait
                for await next in states where next != .wait {
                    state = next
                    break
                }
                guard state == .claim, !Task.isCancelled else { return }
            }
            await nowPlaying.claimSystemPrimary { [weak self] in
                // Rechecked after the activation, right before the request.
                guard !Task.isCancelled, let self, !self.isReleased else { return false }
                return PrimaryClaim(of: coordinator, isReleased: false) == .claim
            }
        }
        pendingPrimaryClaim = claim
        if initial == .claim { await claim.value }
    }

    /// Drops a user play's system-primary claim that isn't made yet.
    private func revokePrimaryClaim() {
        pendingPrimaryClaim?.cancel()
        pendingPrimaryClaim = nil
    }

    /// What a user play's system-primary claim does now.
    private enum PrimaryClaim: Equatable {
        case claim, wait, drop

        @MainActor init(of coordinator: PlaybackCoordinator, isReleased: Bool) {
            guard !isReleased, !coordinator.isRetired, coordinator.isPlaybackRequested, coordinator.error == nil
            else {
                self = .drop
                return
            }
            // As the bridge publishes playing (and so starts the application-primary activation):
            // playing, or stalled with the audio session active.
            let active =
                coordinator.isPlaying || (coordinator.isAudioSessionActive && coordinator.isBuffering)
            self = active ? .claim : .wait
        }
    }

    /// Waits for the pending system-primary claim, if any (tests).
    func waitForPrimaryClaim() async {
        await pendingPrimaryClaim?.value
    }

    // MARK: Queue

    /// The connection's play queue, read-only; `nil` only for a scope built without one (tests).
    public var queue: (any PlaybackQueueReading)? { advancer?.queue }

    /// Changes the queue, unless the scope has retired: from then on its queue stays as saved,
    /// for the connection's next scope to load.
    public func editQueue(_ edit: (PlaybackQueue) -> Void) {
        guard !isRetired, let queue = advancer?.queue else { return }
        edit(queue)
    }

    /// Swaps the account's client and features after a reconnect, without rebuilding anything.
    public func reconnect(client: APIClient?, features: ServerFeatures?) {
        services?.update(client: client, features: features)
    }

    /// Saves the loaded item as the last-played record. Local only.
    public func saveLocally() {
        coordinator.saveLastPlayed()
    }

    // MARK: Server sync

    /// Drains the syncer's pending progress, then uploads the connection's pending local sessions
    /// (``LocalSessionUploader``), in a task the scope owns. Call it while the account is online:
    /// at the session's start with `isFirstSync` (the first sync after login, which also deletes
    /// acknowledged active sessions, ADR 0003), and after each reconnect. The scope calls it too
    /// when the network path comes back online. A call while one runs waits for it, and calls
    /// while one waits join that one, so a flapping path never stacks syncs. Nothing once
    /// retired, and retirement stops one under way: it starts no request after.
    public func syncWithServer(isFirstSync: Bool) {
        guard !isRetired else { return }
        if let queued = queuedServerSync {
            queuedServerSync = queued || isFirstSync
            return
        }
        queuedServerSync = isFirstSync
        let previous = serverSync
        let (syncer, uploader) = (syncer, uploader)
        serverSync = Task { [weak self] in
            await previous?.value
            guard let isFirstSync = self?.startQueuedServerSync() else { return }
            await syncer.drainPendingProgress()
            guard self?.isRetired == false, !Task.isCancelled, let uploader else { return }
            await uploader.sync(isFirstSync: isFirstSync)
        }
    }

    /// Starts the server sync that waited: its `isFirstSync`, or `nil` once retired or cancelled.
    private func startQueuedServerSync() -> Bool? {
        let isFirstSync = queuedServerSync ?? false
        queuedServerSync = nil
        guard !isRetired, !Task.isCancelled else { return nil }
        return isFirstSync
    }

    /// Runs ``syncWithServer(isFirstSync:)`` on each offline-to-online transition, by the
    /// syncer's rule: not on repeated or initial online paths, but on an online path whose
    /// `onlineEpoch` grew (the offline one between was dropped). The syncer drains on the same
    /// transition by itself; this also retries the pending uploads, which the session's
    /// reconnects miss when the account and its client stay the same.
    private func watch(_ paths: AsyncStream<NetworkPath>) {
        pathTask = Task { [weak self] in
            var previous: NetworkPath?
            for await path in paths {
                guard let self, !self.isRetired else { return }
                let reconnected =
                    previous.map { path.isOnline && (!$0.isOnline || path.onlineEpoch != $0.onlineEpoch) } ?? false
                previous = path
                if reconnected { self.syncWithServer(isFirstSync: false) }
                self.pathHandled?(path, reconnected)
            }
        }
    }

    /// Waits for the latest ``syncWithServer(isFirstSync:)`` (tests).
    func waitForServerSync() async {
        await serverSync?.value
    }

    /// Reports the loaded session now and drains pending progress (``ProgressSyncer/flush()``),
    /// for the lifecycle's flush on background and before sign-out or a switch. Returns once
    /// that's done or the caller is cancelled (the lifecycle bounds its flush), whichever comes
    /// first; the syncer's work carries on either way. Nothing once retired.
    public func flush() async {
        guard !isRetired else { return }
        let done = PlaybackCloseResult<Void>()
        let syncer = syncer
        Task {
            await syncer.flush()
            done.resolve(.success(()))
        }
        _ = try? await done.wait()
    }

    /// The server no longer has session `sessionID`: replaces it at the same position, unless the
    /// scope retired or the coordinator moved on (``PlaybackCoordinator/replaceGoneSession(_:)``).
    func sessionGone(_ sessionID: String) {
        guard !isRetired, coordinator.session?.id == sessionID else { return }
        let coordinator = coordinator
        sessionReplacement = Task { await coordinator.replaceGoneSession(sessionID) }
    }

    // MARK: Library progress

    /// Tells ``onProgress`` the loaded media is at `time`; when `spaced`, only once the media time
    /// moved ``progressInterval`` from the last update about the same media.
    private func reportProgress(at time: Double, spaced: Bool = false) {
        guard onProgress != nil, let key = coordinator.mediaKey else { return }
        if spaced, let last = lastProgress, last.key == key, abs(time - last.currentTime) < Self.progressInterval {
            return
        }
        report(PlaybackProgressUpdate(key: key, currentTime: time, duration: coordinator.duration, date: Date()))
    }

    private func report(_ update: PlaybackProgressUpdate) {
        guard let onProgress else { return }
        lastProgress = update
        onProgress(update)
    }

    /// Adds work to run when the scope is released, after the bridge is invalidated (the sleep
    /// timer's detach, #185, a backstop: retirement already cancelled the timer). Runs at once if
    /// the scope was already released.
    public func onRelease(_ body: @escaping @MainActor () -> Void) {
        guard !isReleased else { return body() }
        releaseHooks.append(body)
    }

    /// Cancels the sleep timer and stops the coordinator for good, synchronously: call it before
    /// the teardown first suspends. It captures the final position; expiry, sign-out and removal
    /// also drop the client, so nothing reaches the server after. It cuts off ``onProgress`` first,
    /// so the next account's library never hears this one's playback, and stops the server sync,
    /// the uploader and following the network path. Pass an account-ending reason, never `.user`.
    public func retire(reason: PlaybackStopReason) {
        assert(reason != .user, "A scope retires only for an account-ending reason")
        revokePrimaryClaim()
        // Cut off before the stop: the next account's library must not hear its close.
        onProgress = nil
        serverSync?.cancel()
        pathTask?.cancel()
        pathTask = nil
        services?.setSessionGoneHandler(nil)
        if let uploader { Task { await uploader.cancel() } }
        // Detached before the stop, so nothing it triggers can advance or change the queue, and
        // the sleep timer can't act on the stopped coordinator during the close wait.
        isRetired = true
        advancer?.detach(from: coordinator)
        advancer?.queue.retire()
        sleepTimerAttachment?.detach()
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
        revokePrimaryClaim()
        // Only the syncer's hooks on the coordinator are cut here, after the close wait. The
        // library progress sink (``onProgress``) was cut off in `retire(reason:)`: the library's
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
