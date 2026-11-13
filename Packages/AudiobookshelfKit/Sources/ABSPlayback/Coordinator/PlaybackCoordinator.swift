import ABSAPI
import ABSCore
import ABSData
import Foundation
import Observation
import Synchronization
import os

private let logger = Log.playback

/// Turns "play this" into playback, independent of any scene: checks the streaming policy, opens a
/// server session, loads the engine at the resume position and applies the saved rate. Closes the
/// session when playback stops or the item changes, and restores the last item paused at launch.
///
/// - **Races.** A play that passes the streaming policy, ``stop()`` and ``restoreLastPlayed()``
///   take a new generation. A continuation from an older generation (a session start or engine
///   load finishing late) is dropped, and a session it opened is closed. Policy checks have their
///   own token, so a later play or stop discards a pending one, and a blocked play leaves the
///   current item (and its seeks and resumes) untouched.
/// - **Session starts are serialized.** The server keeps one open session per user and device, so
///   a `/play` that reached it after a newer one would close the newer session, whatever the
///   generations say. Starts therefore take turns, in arrival order: each waits for the previous
///   start to return and for the closes in flight (its stale session's too) before sending
///   anything, and a play superseded while it waits sends no request. A request that hangs delays
///   the next start until it fails (the API client's timeout is 30 s): correctness over latency.
/// - **Closing.** A session is owned by exactly one place: the start continuation until it becomes
///   current, then the coordinator. Whoever drops it closes it once, in the background. The next
///   `/play` waits up to ``closeWaitTimeout`` for closes in flight, so the server normally sees the
///   old session closed first; a slow or failed close never blocks it. That limit counts from when
///   each close was sent, so a hanging close delays only the plays within its first
///   ``closeWaitTimeout``. A close held back by its
///   session's report in flight (at most ``closeWaitTimeout``, #337) is sent before that wait
///   starts, so `/play` never overtakes it. Closes are best effort;
///   P2-06b's final report is plugged in through ``finalCloseReport``.
/// - **Interrupted seeks.** The engine keeps the target of a seek it couldn't finish pending and
///   leaves its own time behind (at 0 after a load). The coordinator treats that target as the
///   position: ``currentTime``, the last-played record and the paused and closing positions use
///   it, a resume seeks to it exactly, and a load's `didSeek` is published when the seek lands.
/// - **Start position.** A new session starts at the newest of the server's progress, the row's
///   audio progress and the last-played record, and the server's wins a tie, as in a sync merge.
///   An unsent audio edit is dated by its edit time and kept over server progress whose audio is
///   still what the row last saw. A synced group is dated by the later of its edit time and the
///   server's row-wide `lastUpdate`, which is only an upper bound for when that group last changed.
/// - **Restore is lazy.** ``restoreLastPlayed()`` only publishes the item, position and display
///   metadata from the ``LastPlayedRecord``; the session starts and the engine loads on the first
///   ``resume(rewindingBy:)`` or play, so opening the app never creates a server session.
@MainActor
@Observable
public final class PlaybackCoordinator {
    public enum Phase: Sendable, Hashable {
        /// No item.
        case idle
        /// An item is current but not loaded: restored at launch, or its start failed.
        case unloaded
        /// The session is starting or the engine is loading.
        case starting
        case loaded
    }

    // MARK: Observable state

    public private(set) var phase: Phase = .idle
    /// Account end permanently retires the coordinator. A later account needs a new instance.
    public private(set) var isRetired = false
    /// The current media (book or podcast episode); stable across sessions of the same media.
    public private(set) var mediaKey: MediaKey?
    /// The current server session: display metadata, chapters and the expanded library item.
    /// Its id is a capability (ADR 0007); never log it.
    public private(set) var session: PlaybackSession?
    /// The latest failure. Cleared when committing to a new session attempt after the policy
    /// check, when the engine accepts a play request, or on stop. A refused start retains the
    /// failure; no-op, seek-only and queued same-item play intents do not themselves clear it.
    public private(set) var error: PlaybackCoordinatorError?
    /// The restored record, for display (title, author, cover, chapter) until the item loads.
    public private(set) var restoredRecord: LastPlayedRecord?
    /// The media a play is checking the streaming policy for, before it commits (a loading hint).
    public private(set) var pendingPlayKey: MediaKey?
    /// The play that ``error``'s `.streamingNeedsConfirmation` blocked, which
    /// ``confirmMeteredStreaming()`` replays.
    private var blockedPlay: (key: MediaKey, startTime: Double?)?
    private var unloadedPosition: Double = 0
    private var unloadedDuration: Double = 0
    /// Where playback is or is going. An interrupted seek leaves the engine's own time behind
    /// (at 0 after a load), so a pending target is the position to report and save.
    private var position: Double { engine.pendingSeekTarget ?? engine.currentTime }

    /// The saved playback rate, applied on every load and play.
    public var rate: Double { settings.playbackRate }
    public var timeline: PlaybackTimeline? { phase == .loaded ? engine.timeline : nil }
    /// Global seconds: while loaded, the engine's confirmed time, or the target of a seek that
    /// hasn't landed (an interrupted one stays pending); else the position play will resume from,
    /// moved by any jumps not yet applied.
    public var currentTime: Double { phase == .loaded ? position : unloadedPositionAfterJumps }
    /// A sample suitable for listening credit, unlike `currentTime` which may be a seek target.
    public var confirmedPlaybackTime: Double? {
        guard phase == .loaded else { return closingPlaybackTime }
        guard !awaitingSeekLanding, engine.pendingSeekTarget == nil,
            engine.state == .playing || engine.state == .paused || engine.state == .ended
        else { return nil }
        return engine.currentTime
    }
    @ObservationIgnored private var closingPlaybackTime: Double?
    /// Read by progress sync during `loaded` to persist explicit intent without reporting play.
    public var loadedPositionIsExplicit: Bool { phase == .loaded && explicitLoadedPosition }
    @ObservationIgnored private var explicitLoadedPosition = false
    public var duration: Double { phase == .loaded ? engine.duration : unloadedDuration }
    public var isPlaying: Bool { phase == .loaded && engine.state == .playing }
    public var isBuffering: Bool {
        switch phase {
        case .starting: true
        case .loaded: engine.state == .buffering || engine.state == .loading
        case .idle, .unloaded: false
        }
    }
    /// Whether the loaded engine has activated its audio session to play
    /// (``AudioEngineProtocol/isAudioSessionActive``); `false` while starting or before the catch-up
    /// seek lands.
    var isAudioSessionActive: Bool { phase == .loaded && engine.isAudioSessionActive }
    public var chapterIndex: Int? { timeline?.currentChapterIndex(at: currentTime) }
    public var chapter: Chapter? { timeline?.currentChapter(at: currentTime) }
    /// The current chapter's span, for chapter-relative times (`elapsed(at:)`, `remaining(at:)`).
    public var chapterRange: TimelineRange? {
        guard let timeline, chapterIndex != nil else { return nil }
        return timeline.progressRange(at: currentTime, chapterTrack: true)
    }
    public var chapterElapsed: Double? { chapterRange?.elapsed(at: currentTime) }
    public var chapterRemaining: Double? { chapterRange?.remaining(at: currentTime) }

    /// Synchronously captures the final report and queues its durable audio-position receipt,
    /// before `sessionWillClose`. Not called for sessions that never loaded. A missing handoff
    /// is an explicit failure of `waitForClose`, even if the bodyless transport succeeds.
    @ObservationIgnored public var finalCloseReport: (@MainActor (ClosingSession) -> PlaybackCloseHandoff?)?
    /// Installed by ProgressSyncer; account end invokes it synchronously before suspension.
    @ObservationIgnored public var quiesceProgressTransport: (@MainActor () -> Void)?
    /// Called once before playback starts or resumes, before the resume seek; returns extra
    /// seconds to rewind (the sleep timer's `playbackWillStart`, P2-08). The extra rewind is
    /// ignored for an explicit start time and for a restart from the end. Assigning it directly
    /// drops the owner recorded by ``setWillResume(_:owner:)``.
    @ObservationIgnored public var willResume: (@MainActor () -> TimeInterval)? {
        didSet { willResumeOwner = nil }
    }
    @ObservationIgnored private weak var willResumeOwner: AnyObject?

    /// Installs `hook` as ``willResume`` on behalf of `owner`; ``clearWillResume(ownedBy:)``
    /// removes it only while `owner` still holds it. `owner` is held weakly, so an object
    /// clearing from its own `deinit` must pass a token it keeps, not itself.
    public func setWillResume(_ hook: @escaping @MainActor () -> TimeInterval, owner: AnyObject) {
        willResume = hook
        willResumeOwner = owner
    }

    public func clearWillResume(ownedBy owner: AnyObject) {
        if willResumeOwner === owner { willResume = nil }
    }

    /// Picks what plays when an item ends (``PlaybackQueueAdvancer/attach(to:)``); without one,
    /// the item stays loaded at its end.
    @ObservationIgnored weak var nextItemProvider: (any NextItemProvider)?

    // MARK: Dependencies

    @ObservationIgnored private let engine: any AudioEngineProtocol
    @ObservationIgnored private let sessions: any PlaybackSessionService
    @ObservationIgnored private let progressStore: any LocalProgressReading
    @ObservationIgnored private let settings: any PlaybackSettingsProviding
    @ObservationIgnored private let policy: any StreamingPolicyChecking
    @ObservationIgnored private let lastPlayedStore: any LastPlayedStoring
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private let mediaLeases: MediaLeases?
    @ObservationIgnored private let backgroundActivity: any BackgroundActivity

    // MARK: Bookkeeping

    @ObservationIgnored private var generation = 0
    /// Observed (like `isFinishingLoad` and `resumingIntent`) because ``isPlaybackRequested``
    /// reads it: a pause while starting changes only this.
    private var playWhenLoaded = true
    /// Loaded, but `play()` hasn't finished: a catch-up seek may be in flight before the engine
    /// starts. Play intent is `playWhenLoaded` until then.
    private var isFinishingLoad = false
    /// A position chosen while starting or unloaded (a seek, or a play with a start time).
    private var pendingStartTime: Double?
    /// Jumps made while starting, or while unloaded without a chosen position; applied after the
    /// resume position is resolved, so they never replace it. Once resolved, the position shown is
    /// the normalized pending absolute start (or `unloadedPosition`) plus this; see `jump(by:)`.
    private var pendingJumpOffset: Double = 0
    /// A new item is starting and its resume position isn't resolved yet, so jumps (which apply
    /// after it) aren't shown: the position stays 0 rather than jump ahead and snap back.
    private var isResolvingStart = false
    @ObservationIgnored private var policyCheck = 0
    /// When playback was last seen playing; drives auto-rewind on resume.
    @ObservationIgnored private var lastPlayedAt: Date?
    @ObservationIgnored private var lastPlayedSavedAt: Date?
    /// The media played to its end; the next play starts again from 0.
    @ObservationIgnored private var reachedEnd = false
    /// A seek's `didSeek` is still owed: after `loaded`, and only once the target lands.
    @ObservationIgnored private var awaitingSeekLanding = false
    /// What an interruption cancelled (``cancelHeldPlayIntent()``): the generation and play check
    /// it happened at.
    @ObservationIgnored private var heldPlay: (generation: Int, policyCheck: Int)?
    /// A restore of ``heldPlay`` queued when the interruption ended, cancelled like a play: by a
    /// pause, lost output, stop or another interruption (which holds it again).
    @ObservationIgnored private var queuedRestore: (token: Int, held: (generation: Int, policyCheck: Int))?
    @ObservationIgnored private var restoreTokens = 0
    /// The ``resumingIntent`` of a user seek that took over recovery's play.
    @ObservationIgnored private var recoverySeekIntent: Int?
    /// Bumped by every resume and pause; a resume plays only if it's still the latest.
    @ObservationIgnored private var resumeIntent = 0
    private var resumingIntent: Int?
    /// Where the latest automatic seek (a resume's rewind, or a load's late landing) landed; its
    /// `didSeek` isn't a user seek (#384).
    @ObservationIgnored public private(set) var resumeRewindLanding: Double?
    /// The latest load's landing is a seek or jump the user made (while it loaded, or replacing
    /// its pending target), not its own target: history records it as a seek even where it lands
    /// exactly on `loaded`'s time (#384).
    @ObservationIgnored public private(set) var loadLandingIsUserSeek = false
    @ObservationIgnored private var seekIsResumeRewind = false
    /// An automatic seek (an interrupted resume rewind, or the load's own) whose landing the engine
    /// still owes; any other seek clears it.
    @ObservationIgnored private var rewindAwaitsLanding = false
    /// How the latest start's server progress moved the stored position (history, #384).
    @ObservationIgnored public private(set) var startProgressChange: ServerAudioPositionChange?
    @ObservationIgnored private var closingSessionIDs: Set<String> = []
    @ObservationIgnored private var closeTasks: [UUID: Task<Void, Never>] = [:]
    /// When each close in ``closeTasks`` was sent, so a hanging one holds back only the first play
    /// after it for ``closeWaitTimeout``, not every play until it times out.
    @ObservationIgnored private var closeSentAt: [UUID: Date] = [:]
    /// An item switch unloaded the engine with its audio session still active (``tearDown(reason:)``);
    /// the next stop, or a failed start, deactivates it.
    @ObservationIgnored private var keepsAudioSession = false
    @ObservationIgnored private var closeOperations: [PlaybackCloseOperation] = []
    @ObservationIgnored private var startTask: Task<StartedSession, any Error>?
    @ObservationIgnored private var resolvingTasks: [UUID: Task<ResolvedStream, any Error>] = [:]
    @ObservationIgnored private var pendingOpenings: [UUID: PlaybackCloseResult<Void>] = [:]
    @ObservationIgnored private var permitsCloseTransport = true
    @ObservationIgnored private let startGate = StartGate()
    @ObservationIgnored private var observers: [PlaybackObserverToken: @MainActor (PlaybackCoordinatorEvent) -> Void] =
        [:]
    @ObservationIgnored private var queuedEvents: [PlaybackCoordinatorEvent] = []
    @ObservationIgnored private var isEmitting = false
    @ObservationIgnored private var advanceTask: Task<Void, Never>?
    /// The advance in flight has begun its start: from then on it is an ordinary play.
    @ObservationIgnored private var isStartingAdvance = false
    /// Item and player failure recovery (ADR 0007); its rebuilds' failures are absorbed by `fail`.
    @ObservationIgnored private let recovery: PlaybackRecovery
    @ObservationIgnored private var recoveryAttempt: Int?
    @ObservationIgnored private var recoveryAttemptError: PlaybackCoordinatorError?
    /// The item the user agreed to stream on a metered network, so its recovery rebuilds don't ask
    /// again; starting another item (also by an auto-advance), or a play without that consent,
    /// clears it.
    @ObservationIgnored private var meteredConsent: MediaKey?
    /// The access token in the loaded stream's URLs: the one a 401 rejected.
    @ObservationIgnored private var streamAccessToken: String?

    /// The last-played record is saved at most this often from time updates.
    static let lastPlayedSaveInterval: TimeInterval = 15
    /// How long a play waits for the previous session's close before starting the next one.
    public static let closeWaitTimeout: Duration = .seconds(2)
    /// A seek while unloaded gives way to server or local progress only if that progress is
    /// really from elsewhere: dated more than this after the last-played record (this device's
    /// own sync lands a little later, plus clock skew) …
    static let otherProgressDateTolerance: TimeInterval = 60
    /// … and more than this many seconds away from the record's position.
    static let otherProgressPositionTolerance: Double = 5

    /// - Parameters:
    ///   - sleep: Times the wait for closes in flight (tests replace it).
    ///   - backgroundActivity: Held while an auto-advance starts the next item with no audio playing.
    ///   - recoveryWait: Times recovery's backoff (tests replace it).
    ///   - networkPaths: The network path recovery waits on (`SystemNetworkPathSource`); `nil`
    ///     treats it as always satisfied.
    ///   - mediaLeases: Shared with the progress actions (#368): each closing session's media is
    ///     held until its close settles, and a start waits for an action on its media. `nil`
    ///     holds and waits for nothing.
    public init(
        engine: any AudioEngineProtocol, sessions: any PlaybackSessionService, progressStore: any LocalProgressReading,
        settings: any PlaybackSettingsProviding, policy: any StreamingPolicyChecking,
        lastPlayedStore: any LastPlayedStoring, now: @escaping @Sendable () -> Date = { .now },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        backgroundActivity: any BackgroundActivity = NoBackgroundActivity(),
        recoveryWait: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        networkPaths: (any NetworkPathSource)? = nil, mediaLeases: MediaLeases? = nil
    ) {
        self.mediaLeases = mediaLeases
        self.backgroundActivity = backgroundActivity
        self.engine = engine
        self.sessions = sessions
        self.progressStore = progressStore
        self.settings = settings
        self.policy = policy
        self.lastPlayedStore = lastPlayedStore
        self.now = now
        self.sleep = sleep
        recovery = PlaybackRecovery(wait: recoveryWait, paths: networkPaths)
        engine.onEvent = { [weak self] event in self?.handle(event) }
        recovery.host = makeRecoveryHost()
    }

    // MARK: Observers

    /// Adds an observer for ``PlaybackCoordinatorEvent``s, delivered on the main actor in order.
    /// Capture the coordinator `[weak self]`-style: it keeps the handler until
    /// ``removeObserver(_:)``. A handler may call back into the coordinator (even ``stop()``);
    /// events that causes are delivered after the current one.
    public func addObserver(_ handler: @escaping @MainActor (PlaybackCoordinatorEvent) -> Void)
        -> PlaybackObserverToken
    {
        let token = PlaybackObserverToken()
        observers[token] = handler
        return token
    }

    public func removeObserver(_ token: PlaybackObserverToken) {
        observers[token] = nil
    }

    private func emit(_ event: PlaybackCoordinatorEvent) {
        queuedEvents.append(event)
        guard !isEmitting else { return }
        isEmitting = true
        defer { isEmitting = false }
        while !queuedEvents.isEmpty {
            let event = queuedEvents.removeFirst()
            for handler in observers.values { handler(event) }
        }
    }

    // MARK: Commands

    /// Plays an item or podcast episode from the server.
    ///
    /// The same media, already loaded, resumes in the same session (from `startTime` when given).
    /// Otherwise the streaming policy is checked first (a block leaves the current item as it is),
    /// then the current session is closed and a new one started at `startTime`, or else at the
    /// newest of server progress, local audio progress and the last-played record (the server's wins
    /// a tie, as when progress is merged), rewound by ``AutoRewind``. Finished media starts from the
    /// beginning.
    /// - Parameter allowingMeteredNetwork: The user agreed to stream on a metered network after
    ///   ``PlaybackCoordinatorError/streamingNeedsConfirmation(_:key:)``. Never overrides "never".
    public func play(
        itemID: String, episodeID: String? = nil, startTime: Double? = nil, allowingMeteredNetwork: Bool = false
    ) async {
        guard !isRetired else { return }
        let key = MediaKey(
            serverConnectionID: sessions.serverConnectionID, libraryItemId: itemID, episodeId: episodeID)
        policyCheck += 1
        let check = policyCheck
        pendingPlayKey = nil
        blockedPlay = nil
        if key == mediaKey {
            switch phase {
            case .loaded where isFinishingLoad:
                // `play()` for this item starts the engine after its catch-up seek; a start time
                // retargets that seek (a later seek replaces it).
                playWhenLoaded = true
                recovery.notePlayIntent(true)
                if let startTime { await seek(to: startTime) }
                return
            case .loaded:
                return await resumeLoaded(rewindingBy: nil, startingAt: startTime)
            case .starting:
                playWhenLoaded = true
                recovery.notePlayIntent(true)
                if let startTime {
                    pendingStartTime = startTime
                    pendingJumpOffset = 0
                }
                return
            case .unloaded where recovery.isRecovering(at: generation):
                // Between failed rebuilds: recovery's next one plays it, within its budget.
                recovery.notePlayIntent(true)
                if let startTime { await seek(to: startTime) }
                return
            case .idle, .unloaded:
                break
            }
        }

        let checkedGeneration = generation
        pendingPlayKey = key
        let decision = await policy.streamingDecision()
        guard check == policyCheck else { return }
        pendingPlayKey = nil
        guard checkedGeneration == generation else { return }
        switch decision {
        case .allowed: break
        case .askUser(let reason) where allowingMeteredNetwork:
            logger.info("Streaming on a metered path (\(String(describing: reason), privacy: .public))")
        case .askUser(let reason):
            return block(.streamingNeedsConfirmation(reason, key: key), startTime: startTime)
        case .denied(let reason): return block(.streamingNotAllowed(reason, key: key))
        }
        meteredConsent = allowingMeteredNetwork ? key : nil
        await start(key: key, startTime: startTime, prepared: nil)
    }

    /// The user agreed to stream on a metered network: replays the play (or queue advance) that
    /// ``error``'s ``PlaybackCoordinatorError/streamingNeedsConfirmation(_:key:)`` blocked, with
    /// its item, episode and start time, allowing the metered path. Does nothing unless that is
    /// still the error, so a confirmation shown for another failure, an earlier block or a
    /// stopped (or retired) coordinator plays nothing. The policy is checked again: "never"
    /// still blocks.
    public func confirmMeteredStreaming() async {
        guard case .streamingNeedsConfirmation(_, let key) = error, let blockedPlay, blockedPlay.key == key
        else { return }
        await play(
            itemID: key.libraryItemId, episodeID: key.episodeId, startTime: blockedPlay.startTime,
            allowingMeteredNetwork: true)
    }

    /// The user declined to stream on a metered network: clears the
    /// ``PlaybackCoordinatorError/streamingNeedsConfirmation(_:key:)`` error and forgets the
    /// blocked play. The current item, if any, carries on as the block left it.
    public func declineMeteredStreaming() {
        guard case .streamingNeedsConfirmation = error else { return }
        blockedPlay = nil
        error = nil
    }

    /// Everything after a play passed the streaming policy. A `prepared` start (an auto-advance)
    /// reuses its server progress instead of fetching it.
    private func start(key: MediaKey, startTime: Double?, prepared: PreparedNextItem?, playing: Bool = true) async {
        // Consent is for one item: an auto-advance (or anything else) starting another drops it,
        // so coming back to the item later asks again; its own rebuilds keep it.
        if meteredConsent != key { meteredConsent = nil }
        let itemID = key.libraryItemId
        let episodeID = key.episodeId
        generation += 1
        let current = generation
        // Retain pending old closes, but not a lifetime history of completed user sessions.
        closeOperations.removeAll {
            $0.transport.result != nil && ($0.handoff == nil || $0.handoff?.position.result != nil)
        }
        let restarting = key == mediaKey
        // A seek while unloaded (restored, or a failed start's start time) is an explicit start,
        // unless progress from elsewhere turns out newer than the last-played record.
        let unloadedSeek = restarting && phase == .unloaded && startTime == nil ? pendingStartTime : nil
        tearDown(reason: restarting ? .restarted : .itemChanged)
        guard current == generation else { return }
        error = nil
        pendingStartTime = startTime ?? unloadedSeek
        // Jumps while the same item was unloaded carry over; a new item or an explicit start drops them.
        if !restarting || startTime != nil { pendingJumpOffset = 0 }
        reachedEnd = false
        playWhenLoaded = playing
        phase = .starting
        if !restarting {
            mediaKey = key
            lastPlayedAt = nil
            restoredRecord = nil
            unloadedPosition = 0
            unloadedDuration = 0
            isResolvingStart = true
            emit(.itemChanged(key))
        }
        guard current == generation else { return }

        // A progress action on this media (#368) finishes first, so the start reads its result. The
        // wait comes before the opening is registered: until it ends no request is issued, so an
        // account end mustn't wait for it, and the generation check drops the start after one.
        if let mediaLeases, mediaLeases.isHeld(key, by: .progressAction) {
            await mediaLeases.waitUntilFree(key, of: .progressAction)
            guard current == generation else { return }
            if Task.isCancelled {
                // A cancelled caller abandons the start; that isn't a failure.
                if phase == .starting { phase = .unloaded }
                releaseKeptAudioSession()
                return
            }
        }

        let openingID = UUID()
        let opening = PlaybackCloseResult<Void>()
        pendingOpenings[openingID] = opening
        defer {
            opening.resolve(.success(()))
            pendingOpenings[openingID] = nil
        }
        let started: StartedSession
        do {
            guard
                let result = try await startSessionSerially(
                    itemID: itemID, episodeID: episodeID, generation: current, prepared: prepared)
            else { return }
            started = result
        } catch is CancellationError {
            // A cancelled caller abandons the start; that isn't a failure. No session was opened.
            if current == generation, phase == .starting { phase = .unloaded }
            if current == generation { releaseKeptAudioSession() }
            return
        } catch {
            return fail(Self.sessionError(error), generation: current)
        }
        let session = started.session
        guard current == generation else {
            closeInBackground(sessionID: session.id, report: nil)
            return
        }

        let source: AudioEngineSource
        let stream: ResolvedStream
        do {
            stream = try await resolveStream(for: session)
            source = try makeSource(session: session, stream: stream)
        } catch {
            closeInBackground(sessionID: session.id, report: nil)
            // A cancelled caller abandons the start; that isn't a failure.
            if error is CancellationError {
                if current == generation, phase == .starting { phase = .unloaded }
                if current == generation { releaseKeptAudioSession() }
                return
            }
            return fail(Self.streamError(error), generation: current)
        }
        guard current == generation else {
            closeInBackground(sessionID: session.id, report: nil)
            return
        }
        // From here the coordinator owns the session: whoever replaces it closes it.
        self.session = session
        streamAccessToken = stream.accessToken
        // From here teardown can capture this known session without waiting for the engine load.
        opening.resolve(.success(()))
        pendingOpenings[openingID] = nil
        unloadedDuration = source.timeline.duration
        emit(.sessionStarted(sessionID: session.id, key: key))

        // Keep the original selection inputs: a newly cached server value is not local intent.
        let local: LocalMediaProgressDTO?
        var localReadSucceeded = false
        do {
            local = try await progressStore.progress(for: key)
            localReadSucceeded = true
        } catch {
            local = nil
        }
        let server = started.serverProgress
        guard current == generation else { return }
        // On equal dates the first candidate wins, so the server's goes first: an unsent edit beats
        // server progress only when strictly newer, as when ``ProgressSyncState`` merges.
        var candidates: [ProgressCandidate] = []
        switch server {
        case .success(let progress?):
            // An unsent audio edit stays the newest audio while the server's is as the row last saw
            // it: the server's date is row-wide, so another device's ebook or finished change moves it.
            if let local, local.audioDirty, local.serverAudioUnchanged(in: progress) { break }
            // The position, date and flag all come from the fetched progress: `/play` may
            // have captured an older position than the fetch returned.
            if progress.isFinished || progress.currentTime > 0 || progress.duration > 0 {
                candidates.append(
                    ProgressCandidate(
                        currentTime: progress.currentTime, updatedAt: progress.lastUpdate.map(Self.date(ms:)),
                        isFinished: progress.isFinished))
            } else {
                candidates.append(ProgressCandidate(currentTime: session.currentTime, updatedAt: nil))
            }
        case .success(nil):
            candidates.append(ProgressCandidate(currentTime: session.currentTime, updatedAt: nil))
        case .failure(let error):
            // Undated: the session position is used only when there is nothing else.
            logger.info("Server progress unavailable (\(Self.caseName(error), privacy: .public))")
            candidates.append(ProgressCandidate(currentTime: session.currentTime, updatedAt: nil))
        }
        // Dated by the audio and completion groups alone, never `lastUpdate`, which ebook edits bump.
        // A row with no saved audio has no position to offer, so a finished-only edit on it (an item
        // never played here, marked finished) adds no candidate: its flag carries no position, and
        // the server's progress, which has the flag once sent, or the record is the position to use.
        // Completion remains authoritative even when older than the audio edit: audio-only local
        // edits do not infer an unfinish. If this candidate wins while still finished,
        // ResumePosition starts at zero unless an explicit start time was supplied.
        if let local, let audioSavedAt = local.audioSavedAt {
            let finishedSavedAt = local.isFinished || local.finishedDirty ? local.finishedSavedAt : nil
            candidates.append(
                ProgressCandidate(
                    currentTime: local.currentTime, updatedAt: max(audioSavedAt, finishedSavedAt ?? audioSavedAt),
                    isFinished: local.isFinished))
        }
        let record = lastPlayedStore.load().flatMap { $0.key == key ? $0 : nil }
        if let record {
            candidates.append(
                ProgressCandidate(
                    currentTime: record.position, updatedAt: record.timestamp, isFinished: record.isFinished))
        }
        // Kept until the load succeeds, so a retry after a failure starts there again.
        var plannedStart = pendingStartTime
        var explicitStart = plannedStart
        if let unloadedSeek, explicitStart == unloadedSeek, let record,
            candidates.contains(where: { Self.isFromElsewhere($0, than: record) })
        {
            explicitStart = nil
        }
        let extra = playWhenLoaded ? Self.nonNegative(willResume?() ?? 0) : 0
        guard current == generation else { return }
        let resumeTime = ResumePosition.startTime(
            explicit: explicitStart, candidates: candidates, duration: source.timeline.duration, now: now(),
            autoRewind: !settings.disableAutoRewind)
        let target = explicitStart == nil ? max(resumeTime - extra, 0) : resumeTime

        if plannedStart != nil, explicitStart == nil {
            // Foreign progress superseded the unloaded seek. Keep the resolved anchor for jumps
            // and load-failure retries; an absolute seek during the load can still replace it.
            plannedStart = target
            pendingStartTime = target
        }
        engine.setRate(Float(rate))
        unloadedPosition = target
        isResolvingStart = false
        do {
            try await engine.load(source, at: target)
        } catch .superseded {
            return
        } catch {
            guard current == generation else { return }
            tearDown(reason: .loadFailed)
            return fail(PlaybackCoordinatorError(engineError: error), generation: current)
        }
        guard current == generation else { return }
        // Admit only after a successful load. Invalidation prevents a new submission, not an
        // already submitted actor mutation; the store independently checks atomic provenance.
        startProgressChange = nil
        var progressChange: ServerAudioPositionChange?
        if !Task.isCancelled, localReadSucceeded, let capture = started.progressCapture,
            case .success(let progress?) = server
        {
            progressChange = try? await progressStore.applyStartProgressChange(progress, captured: capture)
        }
        guard current == generation else { return }
        startProgressChange = progressChange
        phase = .loaded
        isFinishingLoad = true
        defer { if current == generation { isFinishingLoad = false } }
        restoredRecord = nil
        lastPlayedAt = nil
        let intent = resumeIntent
        let pending = pendingStartTime
        pendingStartTime = nil
        let jumpOffset = pendingJumpOffset
        pendingJumpOffset = 0
        awaitingSeekLanding = true
        // However late the engine lands the load's own target, that's not a user seek (#384).
        rewindAwaitsLanding = true
        resumeRewindLanding = nil
        loadLandingIsUserSeek = false
        var seekTarget: Double?
        if let pending, pending != plannedStart {
            // A seek while loading: normalize before adding jumps, just as the initial load does.
            seekTarget = Self.clamp(pending, to: unloadedDuration)
        }
        // Use the requested resume anchor (or newer seek), not the engine's gap-snapped landing.
        if jumpOffset != 0 { seekTarget = (seekTarget ?? target) + jumpOffset }
        if let seekTarget {
            // A seek or jump made while loading replaces the load's own target: a user seek.
            rewindAwaitsLanding = false
            loadLandingIsUserSeek = true
            await engine.seek(to: engine.timeline?.clamp(seekTarget) ?? seekTarget)
            guard current == generation, phase == .loaded else { return }
        }
        // An interrupted initial seek stays pending with the engine paused at 0: `.loaded` carries
        // its target, and `.didSeek` waits for the landing (see `handle(_:)`).
        explicitLoadedPosition = explicitStart != nil || seekTarget != nil
        emit(.loaded(time: position))
        guard current == generation, phase == .loaded else { return }
        // Even a newer seek or tick during catch-up must report its landing after `loaded`.
        if engine.pendingSeekTarget == nil, awaitingSeekLanding {
            awaitingSeekLanding = false
            rewindAwaitsLanding = false
            emit(.didSeek(time: engine.currentTime))
        }
        guard current == generation, phase == .loaded else { return }
        saveLastPlayed()
        // A pause or resume during the seek above takes over.
        if playWhenLoaded, intent == resumeIntent { startEngine() }
    }

    /// Plays the current item: resumes a loaded one (rewinding by `seconds`, or by ``AutoRewind``
    /// for the time since it last played), or starts a session for a restored or failed one.
    public func resume(rewindingBy seconds: Double? = nil) async {
        guard !isRetired, let key = mediaKey else { return }
        switch phase {
        case .idle: return
        case .starting,
            .loaded where isFinishingLoad:
            playWhenLoaded = true
            // A recovery rebuild that fails carries this on to the next attempt.
            recovery.notePlayIntent(true)
        case .unloaded where recovery.isRecovering(at: generation):
            // Recovery's next rebuild plays it, within its budget.
            recovery.notePlayIntent(true)
        case .unloaded: await play(itemID: key.libraryItemId, episodeID: key.episodeId)
        case .loaded: await resumeLoaded(rewindingBy: seconds, startingAt: nil)
        }
    }

    /// The user resume path for loaded media. In order: ``willResume``; one awaited seek (to
    /// `startTime`, else exactly to the target of an interrupted seek still pending, else to 0
    /// after the end, else back by `seconds` or ``AutoRewind``), which emits
    /// ``PlaybackCoordinatorEvent/didSeek(time:)`` with where it landed; then play. A pause during
    /// the seek cancels the play, and a resume while one is in flight is ignored (a `startTime`
    /// replaces it). While already playing, a `startTime` is only a seek.
    private func resumeLoaded(rewindingBy seconds: Double?, startingAt startTime: Double?) async {
        recovery.notePlayIntent(true)
        let time = engine.currentTime
        let atEnd = reachedEnd || engine.state == .ended
        let hasPendingSeek = engine.pendingSeekTarget != nil
        if let startTime, engine.isPlaybackRequested, !atEnd, resumingIntent == nil {
            // Already playing: just move.
            await seek(to: startTime)
            return
        }
        guard
            startTime != nil
                || (resumingIntent == nil && (atEnd || hasPendingSeek || !engine.isPlaybackRequested))
        else { return }
        resumeIntent += 1
        let intent = resumeIntent
        let current = generation
        resumingIntent = intent
        defer { if resumingIntent == intent { resumingIntent = nil } }

        let extra = Self.nonNegative(willResume?() ?? 0)
        guard current == generation else { return }
        let target: Double?
        var isRewind = false
        if let startTime {
            target = startTime
        } else if let pending = engine.pendingSeekTarget {
            // The user's interrupted seek is where playback goes: not rewound from the old
            // position, nor replaced by the restart from the end. Retrying an interrupted resume
            // rewind keeps it a rewind, not a user seek.
            target = pending
            isRewind = rewindAwaitsLanding
        } else if atEnd {
            target = 0
        } else {
            let rewound =
                if let seconds {
                    time - Self.nonNegative(seconds)
                } else {
                    AutoRewind.resumeTime(
                        currentTime: time, lastPlayed: lastPlayedAt, now: now(), isEnabled: !settings.disableAutoRewind)
                }
            let rewoundTarget = max(rewound - extra, 0)
            target = rewoundTarget < time ? rewoundTarget : nil
            isRewind = true
        }
        if let target {
            seekIsResumeRewind = isRewind
            await seek(to: target)
        }
        guard intent == resumeIntent, current == generation, phase == .loaded else { return }
        startEngine()
    }

    /// Pauses, and cancels a play waiting on its streaming-policy check (``pendingPlayKey``).
    /// Always emits `paused`, even when already paused, so a sleep timer's pending resume can be cancelled.
    public func pause() {
        defer { emit(.paused(time: currentTime)) }
        dropHeldPlay()
        recovery.notePlayIntent(false)
        if pendingPlayKey != nil {
            policyCheck += 1
            pendingPlayKey = nil
        }
        switch phase {
        case .starting: playWhenLoaded = false
        case .loaded where isFinishingLoad: playWhenLoaded = false
        case .loaded:
            resumeIntent += 1
            resumingIntent = nil
            guard engine.isPlaybackRequested else { return }
            engine.pause()
            lastPlayedAt = now()
            saveLastPlayed()
        case .idle, .unloaded: return
        }
    }

    /// Seeks to a global time and returns where playback landed, or `nil` when a later seek
    /// replaced it or it failed. While starting, the target is applied once loaded (`nil`). While
    /// unloaded, moves the position shown, and the next play starts exactly there with no rewind,
    /// unless server or local progress from elsewhere is newer than the last-played record (see
    /// `otherProgressDateTolerance`).
    @discardableResult
    public func seek(to time: Double) async -> Double? { await seekOutcome(to: time).landedTime }

    private func seekOutcome(to time: Double) async -> JumpOutcome {
        switch phase {
        case .loaded:
            let current = generation
            let target = engine.timeline?.clamp(time) ?? max(time, 0)
            let isResumeRewind = seekIsResumeRewind
            seekIsResumeRewind = false
            resumeRewindLanding = nil
            rewindAwaitsLanding = false
            if !isResumeRewind { loadLandingIsUserSeek = true }
            reachedEnd = false
            awaitingSeekLanding = true
            // A seek during recovery takes over, and plays once it lands if recovery would have: a
            // resume intent, so a pause (or lost output) meanwhile cancels it. A rebuild finishing
            // its load stays in charge: the load path plays it.
            var resume: Int?
            // One replacing such a seek in flight takes over its play.
            let replacesRecoverySeek = resumingIntent != nil && resumingIntent == recoverySeekIntent
            if !isFinishingLoad, recovery.yieldToSeek() || replacesRecoverySeek {
                resumeIntent += 1
                resume = resumeIntent
                resumingIntent = resume
                recoverySeekIntent = resume
            }
            defer { if let resume, resumingIntent == resume { resumingIntent = nil } }
            let result = await engine.seek(to: target)
            guard current == generation, phase == .loaded else { return .deferred }
            // A newer seek owns the landing state now.
            guard result != .superseded else { return .deferred }
            guard result == .completed else {
                awaitingSeekLanding = isFinishingLoad || engine.pendingSeekTarget != nil
                // The engine keeps an interrupted or failed target pending; a retry is still the rewind.
                rewindAwaitsLanding = isResumeRewind && engine.pendingSeekTarget != nil
                // An interrupted seek that took over recovery reports no failure, so recovery won't
                // run again: keep its play, which the engine starts once the pending target lands.
                if result == .interrupted, let resume, resume == resumeIntent, !isFinishingLoad,
                    !engine.isPlaybackRequested
                {
                    startEngine()
                }
                return result == .failed ? .failed : .deferred
            }
            let landed = engine.currentTime
            if awaitingSeekLanding, !isFinishingLoad {
                awaitingSeekLanding = false
                if isResumeRewind { resumeRewindLanding = landed }
                emit(.didSeek(time: landed))
                saveLastPlayed()
            }
            if let resume, resume == resumeIntent, current == generation, phase == .loaded, !isFinishingLoad,
                !engine.isPlaybackRequested
            {
                startEngine()
            }
            return .landed(landed)
        case .unloaded:
            let finite = time.isFinite ? max(time, 0) : 0
            unloadedPosition = unloadedDuration > 0 ? min(finite, unloadedDuration) : finite
            pendingStartTime = unloadedPosition
            pendingJumpOffset = 0
            return .landed(unloadedPosition)
        case .starting:
            pendingStartTime = time
            pendingJumpOffset = 0
            return .deferred
        case .idle:
            return .deferred
        }
    }

    /// Jumps by `offset` seconds (negative jumps back), clamped to the item, and returns where
    /// playback landed (`nil` as for ``seek(to:)``). Loaded, the jump is relative to the latest
    /// seek's target while one is in flight, so rapid jumps add up. While starting, jumps add up and
    /// apply after the resume position is resolved, so they never replace it. Unloaded, a jump
    /// moves a chosen position (after a ``seek(to:)``), or else moves the position shown and
    /// applies after the resume position is resolved, keeping the progress-from-elsewhere rule.
    @discardableResult
    public func jump(by offset: Double) async -> Double? { await jumpOutcome(by: offset).landedTime }

    /// Jumps as ``jump(by:)`` does and reports how this jump ended, telling a target that failed to
    /// load apart from one queued while starting or superseded by a later seek or item.
    @discardableResult
    public func jumpOutcome(by offset: Double) async -> JumpOutcome {
        guard offset.isFinite, offset != 0 else { return .deferred }
        switch phase {
        case .loaded:
            return await seekOutcome(to: (engine.pendingSeekTarget ?? engine.currentTime) + offset)
        case .starting:
            // Clamped like an unloaded jump once the item's duration is known.
            if isResolvingStart || unloadedDuration == 0 { pendingJumpOffset += offset } else { addClampedJump(offset) }
            return .deferred
        case .unloaded:
            if let pendingStartTime {
                return await seekOutcome(to: Self.clamp(pendingStartTime, to: unloadedDuration) + offset)
            }
            addClampedJump(offset)
            return .landed(unloadedPositionAfterJumps)
        case .idle:
            return .deferred
        }
    }

    /// Whether the user wants playback: true while a play waits on its streaming-policy check,
    /// while starting to play (until the engine starts), and while loaded and playing, buffering,
    /// seeking or resuming, unlike ``isPlaying``. Drives play/pause toggles.
    public var isPlaybackRequested: Bool {
        if pendingPlayKey != nil { return true }
        switch phase {
        case .starting: return playWhenLoaded
        case .loaded where isFinishingLoad: return playWhenLoaded
        case .loaded:
            return engine.isPlaybackRequested || resumingIntent != nil || recovery.wantsPlay(at: generation)
        // Between failed rebuilds: the restart recovery will make.
        case .unloaded: return recovery.wantsPlay(at: generation)
        case .idle: return false
        }
    }

    /// Whether recovery is waiting for the network to return before its next attempt (ADR 0007's
    /// "Waiting for network"), spending none of its budget; it gives up after five minutes.
    public var isWaitingForNetwork: Bool { recovery.isWaitingForNetwork(at: generation) }

    /// Sets and saves the playback rate. Rates the settings reject are ignored.
    public func setRate(_ rate: Double) {
        settings.playbackRate = rate
        engine.setRate(Float(self.rate))
    }

    /// Replaces a session the server no longer has (its `/sync` answered 404, as after a server
    /// restart) with a new one for the same media at ``currentTime``, playing only if playback was
    /// requested: an explicit start, like recovery's rebuild, so neither server progress nor
    /// auto-rewind moves it (#184). Does nothing unless `sessionID` is still the loaded session,
    /// or while a play waits on its streaming-policy check or recovery is rebuilding.
    public func replaceGoneSession(_ sessionID: String) async {
        guard !isRetired, phase == .loaded, session?.id == sessionID, let key = mediaKey, pendingPlayKey == nil,
            !recovery.isRecovering(at: generation)
        else { return }
        logger.info("The server no longer has the playback session; starting a new one at the same position")
        // A play an interruption held still holds it on the new session (`start` takes
        // `generation + 1` at once).
        if heldPlay?.generation == generation { heldPlay?.generation = generation + 1 }
        await start(key: key, startTime: currentTime, prepared: nil, playing: isPlaybackRequested)
    }

    /// Ordinary user stop remains reusable and clears LastPlayed. Account end permanently
    /// retires this coordinator; switch/expiry retain a valid matching record, sign-out/removal
    /// clear only this connection's record. Capture and transport quiescence are synchronous.
    public func stop(reason: PlaybackStopReason = .user) {
        guard !isRetired else { return }
        cancelAutoAdvance()
        if reason != .user {
            isRetired = true
            startTask?.cancel()
            for task in resolvingTasks.values { task.cancel() }
            quiesceProgressTransport?()
            if !reason.permitsTransport {
                permitsCloseTransport = false
                for operation in closeOperations {
                    operation.task?.cancel()
                    operation.transport.resolve(.success(false))
                }
            }
            if reason == .accountSwitch || reason == .expired { preserveLastPlayedAtAccountEnd() }
        }
        generation += 1
        policyCheck += 1
        pendingPlayKey = nil
        dropHeldPlay()
        let hadItem = mediaKey != nil
        tearDown(reason: .stopped)
        mediaKey = nil
        error = nil
        restoredRecord = nil
        pendingStartTime = nil
        pendingJumpOffset = 0
        isResolvingStart = false
        reachedEnd = false
        unloadedPosition = 0
        unloadedDuration = 0
        phase = .idle
        if reason == .user
            || ((reason == .signOut || reason == .accountRemoved)
                && lastPlayedStore.load()?.serverConnectionID == sessions.serverConnectionID)
        {
            lastPlayedStore.clear()
        }
        if hadItem { emit(.itemChanged(nil)) }
    }

    /// Publishes the last-played item for this connection, paused at its saved position, with
    /// its display metadata in ``restoredRecord``, without starting a session or loading the
    /// engine. Returns whether an item was restored. A progress action on the record's media
    /// (``MediaLeases``) skips it: the action clears the record, and a snapshot taken first would
    /// save the old position again at account end (#368).
    @discardableResult
    public func restoreLastPlayed() -> Bool {
        guard !isRetired, phase == .idle, let record = lastPlayedStore.load(),
            record.serverConnectionID == sessions.serverConnectionID,
            mediaLeases?.isHeld(record.key, by: .progressAction) != true
        else { return false }
        generation += 1
        mediaKey = record.key
        restoredRecord = record
        unloadedPosition = record.position.isFinite ? max(record.position, 0) : 0
        unloadedDuration = record.duration ?? 0
        lastPlayedAt = record.timestamp
        phase = .unloaded
        emit(.itemChanged(record.key))
        return true
    }

    private func preserveLastPlayedAtAccountEnd() {
        let saved = lastPlayedStore.load()
        guard saved == nil || saved?.serverConnectionID == sessions.serverConnectionID,
            let key = mediaKey
        else { return }
        if phase == .loaded {
            guard currentTime.isFinite, currentTime >= 0 else { return }
            saveLastPlayed()
            return
        }
        // An unresolved new start has no position. A relative jump alone is not an anchor.
        guard pendingStartTime != nil || (!isResolvingStart && (restoredRecord != nil || session != nil)) else {
            return
        }
        let base = pendingStartTime ?? unloadedPosition
        guard base.isFinite else { return }
        let time = Self.clamp(Self.clamp(base, to: unloadedDuration) + pendingJumpOffset, to: unloadedDuration)
        var record =
            restoredRecord ?? saved.flatMap { $0.key == key ? $0 : nil }
            ?? LastPlayedRecord(
                serverConnectionID: key.serverConnectionID, libraryItemID: key.libraryItemId,
                episodeID: key.episodeId, position: time, duration: unloadedDuration > 0 ? unloadedDuration : nil,
                timestamp: now(), title: session?.displayTitle, author: session?.displayAuthor,
                coverPath: session?.coverPath)
        // Preserve the timestamp/finished flag of untouched restored metadata.
        if pendingStartTime != nil || pendingJumpOffset != 0 || phase == .starting {
            record.position = time
            record.timestamp = now()
            record.isFinished = false
        }
        lastPlayedStore.save(record)
    }

    /// Saves the loaded item's position as the last-played record. Call when the app moves to
    /// the background; pauses, seeks, loads and the end save it already.
    public func saveLastPlayed() {
        guard let key = mediaKey, phase == .loaded else { return }
        let date = now()
        lastPlayedSavedAt = date
        // A podcast episode shows its show as the author (as Now Playing does).
        var author = session?.displayAuthor
        if case .podcast(let show) = session?.mediaMetadata { author = show.title }
        lastPlayedStore.save(
            LastPlayedRecord(
                serverConnectionID: key.serverConnectionID, libraryItemID: key.libraryItemId,
                episodeID: key.episodeId, position: currentTime, duration: duration > 0 ? duration : nil,
                timestamp: date, isFinished: reachedEnd, title: session?.displayTitle, author: author,
                coverPath: session?.coverPath, chapterTitle: chapter?.title))
    }

    // MARK: Engine events

    private func handle(_ event: AudioEngineEvent) {
        // In every phase: a recovery rebuild may be starting, or waiting between attempts.
        if event == .outputLost { return outputLost() }
        guard phase == .loaded else { return }
        switch event {
        case .tick(let time):
            // An internal engine.play() retry has no awaited coordinator seek completion.
            // Its owed didSeek waits for the first tick with no pending target after loaded;
            // clearing the flag before emitting prevents later ticks from announcing it again.
            if awaitingSeekLanding, !isFinishingLoad, engine.pendingSeekTarget == nil {
                awaitingSeekLanding = false
                if rewindAwaitsLanding { resumeRewindLanding = engine.currentTime }
                rewindAwaitsLanding = false
                emit(.didSeek(time: engine.currentTime))
                guard phase == .loaded else { return }
                saveLastPlayed()
            }
            if engine.state == .playing {
                let date = now()
                recovery.notePlaying(at: date, generation: generation)
                lastPlayedAt = date
                if lastPlayedSavedAt.map({ date.timeIntervalSince($0) >= Self.lastPlayedSaveInterval }) ?? true {
                    saveLastPlayed()
                }
            } else {
                recovery.notePlaybackStopped()
            }
            emit(.tick(time: time))
        case .trackChanged:
            break
        case .endOfMedia:
            reachedEnd = true
            lastPlayedAt = now()
            saveLastPlayed()
            // Taken before the observers run, so one that pauses or stops on the end (the sleep
            // timer) cancels the advance.
            let ended = AdvanceSnapshot(generation: generation, intent: resumeIntent, playRequest: policyCheck)
            let key = mediaKey
            emit(.ended)
            if let key { beginAdvance(after: key, ended) }
        case .failed(.itemFailed(_, let failure)), .failed(.playerFailed(let failure)):
            // A resume awaiting its seek (a user's, or one that took over recovery) wants play too.
            recovery.recover(
                from: failure, generation: generation,
                wasPlaying: engine.wasPlaybackRequestedAtFailure || resumingIntent != nil)
        case .failed(let failure):
            let error = PlaybackCoordinatorError(engineError: failure)
            self.error = error
            emit(.failed(error))
        case .outputLost:
            break
        }
    }

    /// The engine paused for a lost output: plays held outside it (recovery's, a resume awaiting
    /// its seek, a start's) must not restart on the speaker. Like ``pause()``, always emits `paused`,
    /// even when already paused, so a sleep timer's pending resume is cancelled too.
    private func outputLost() {
        defer { emit(.paused(time: currentTime)) }
        dropHeldPlay()
        // As a pause does: a play awaiting its streaming check doesn't start.
        if pendingPlayKey != nil {
            policyCheck += 1
            pendingPlayKey = nil
        }
        recovery.notePlayIntent(false)
        resumeIntent += 1
        resumingIntent = nil
        playWhenLoaded = false
    }

    /// An interruption (a call) began: drops a play held outside the engine, which the engine's
    /// pause can't reach, as a lost output does, so recovery never restarts audio during the call.
    /// Returns whether there was one.
    public func cancelHeldPlayIntent() -> Bool {
        // A play awaiting its streaming check never starts during the call, even beside a playing
        // item; it isn't restored.
        if pendingPlayKey != nil {
            policyCheck += 1
            pendingPlayKey = nil
        }
        // The last call's restore hasn't run yet: held again, for this call's end.
        if let restore = queuedRestore {
            queuedRestore = nil
            heldPlay = restore.held
            return true
        }
        // Nothing new to cancel (a repeated begin): what an earlier one held stays held.
        guard isPlaybackRequested, !engine.isPlaybackRequested else { return heldPlay != nil }
        if phase == .starting || (phase == .loaded && isFinishingLoad) {
            // Keeps the load's resume token, so restoring `playWhenLoaded` plays it.
            pause()
        } else {
            outputLost()
        }
        heldPlay = (generation, policyCheck)
        return true
    }

    /// The interruption ended with a resumption recommended: restores the play it cancelled, unless
    /// playback changed since (a pause, lost output, play, stop or another item). Recovery still in
    /// charge only gets its play intent back: no rewind or seek of the coordinator's own.
    public func resumeHeldPlayIntent() {
        guard let held = heldPlay else { return }
        heldPlay = nil
        guard held == (generation, policyCheck), mediaKey != nil else { return }
        switch phase {
        case .starting,
            .loaded where isFinishingLoad:
            playWhenLoaded = true
            recovery.notePlayIntent(true)
        case _ where recovery.isRecovering(at: generation):
            recovery.notePlayIntent(true)
        case .loaded:
            let intent = resumeIntent
            restoreTokens += 1
            let token = restoreTokens
            queuedRestore = (token, held)
            Task { [weak self] in
                guard let self, queuedRestore?.token == token else { return }
                queuedRestore = nil
                guard held == (generation, policyCheck), phase == .loaded, intent == resumeIntent else { return }
                if recovery.isRecovering(at: generation) { return recovery.notePlayIntent(true) }
                await resume()
            }
        case .idle, .unloaded:
            break
        }
    }

    /// The interruption ended without a resumption: what it cancelled stays cancelled, and a later
    /// interruption's end doesn't restore it.
    public func discardHeldPlayIntent() {
        dropHeldPlay()
    }

    /// A user pause, lost output or stop: nothing an interruption cancelled is restored.
    private func dropHeldPlay() {
        heldPlay = nil
        queuedRestore = nil
    }

    // MARK: Auto-advance

    /// What a start fetches before `/play` (the streaming decision and server progress, after
    /// capturing local progress as a start does), done ahead of time for the item to follow.
    func prepareStart(for key: MediaKey) async -> PreparedNextItem {
        let actions = mediaLeases?.actionGeneration(of: key)
        let capture = try? await progressStore.captureStartProgress(for: key)
        let progress = await Self.serverProgress(sessions, itemID: key.libraryItemId, episodeID: key.episodeId)
        let decision = await policy.streamingDecision()
        return PreparedNextItem(
            key: key, decision: decision, serverProgress: progress, progressCapture: capture,
            actionGeneration: actions)
    }

    /// Starts the next item after `key` ended, holding background activity from now until the
    /// start succeeds, fails or is cancelled. A play, pause, seek, stop or detach before the
    /// start cancels it, as does any play request, even one the streaming policy blocks. Once the
    /// start has begun it is an ordinary play: a pause loads the next item paused, and a detach
    /// leaves it to finish.
    private func beginAdvance(after key: MediaKey, _ ended: AdvanceSnapshot) {
        guard let provider = nextItemProvider, isAdvancing(after: key, ended) else { return }
        advanceTask?.cancel()
        let activity = backgroundActivity
        let token = activity.begin(name: "Auto-advance")
        advanceTask = Task { [weak self] in
            defer { activity.end(token) }
            await self?.advance(after: key, provider: provider, ended)
        }
    }

    private func advance(after key: MediaKey, provider: any NextItemProvider, _ ended: AdvanceSnapshot) async {
        var next = provider.preparedNext(after: key)
        if next == nil { next = await provider.prepareNext(after: key) }
        // Anything the user did meanwhile (play, pause, seek, stop), or a detach, cancels it.
        guard let next, !Task.isCancelled, nextItemProvider === provider,
            isAdvancing(after: key, ended)
        else { return }
        // The path and setting now decide, not the prepared (possibly stale) decision; no waiting.
        switch policy.currentStreamingDecision() {
        case .allowed: break
        // Nobody can agree to a metered network at the lock screen; the item stays queued, and
        // ``confirmMeteredStreaming()`` plays it.
        case .askUser(let reason): return block(.streamingNeedsConfirmation(reason, key: next.key))
        case .denied(let reason): return block(.streamingNotAllowed(reason, key: next.key))
        }
        let endedAt = (position: position, duration: engine.duration, lastPlayedAt: lastPlayedAt)
        let attempt = generation + 1
        isStartingAdvance = true
        await start(key: next.key, startTime: nil, prepared: next)
        isStartingAdvance = false
        // The next item left the queue during the close wait, so its start sent nothing (#338):
        // back to the end of the item that ended, rather than leave the removed one selected.
        // Not once the user asked for another item: a play still in its policy check hasn't
        // bumped `generation` yet, but has the play-request counter.
        guard generation == attempt, policyCheck == ended.playRequest, pendingPlayKey == nil,
            phase == .unloaded, mediaKey == next.key, error == nil,
            nextItemProvider?.isStillNext(next.key) == false
        else { return }
        generation += 1
        mediaKey = key
        restoredRecord = lastPlayedStore.load().flatMap { $0.key == key ? $0 : nil }
        unloadedPosition = endedAt.position
        unloadedDuration = endedAt.duration
        lastPlayedAt = endedAt.lastPlayedAt
        isResolvingStart = false
        // Seeks and jumps made while the removed item was starting were for it, not this one.
        pendingStartTime = nil
        pendingJumpOffset = 0
        emit(.itemChanged(key))
    }

    /// What the advance must find unchanged when the item ended: the generation, the resume
    /// intent and the play requests (``play(itemID:episodeID:startTime:allowingMeteredNetwork:)``).
    private struct AdvanceSnapshot {
        let generation: Int
        let intent: Int
        let playRequest: Int
    }

    /// The item that ended is still current, at its end, with nothing played (or requested to,
    /// even if blocked, or waiting on its policy check), paused, sought or stopped since.
    private func isAdvancing(after key: MediaKey, _ ended: AdvanceSnapshot) -> Bool {
        !isRetired && phase == .loaded && mediaKey == key && reachedEnd && generation == ended.generation
            && resumeIntent == ended.intent && policyCheck == ended.playRequest && pendingPlayKey == nil
    }

    /// Cancels the advance while it prepares; once its start has begun, that finishes as an
    /// ordinary play (`stop()` and retirement still cancel it, by their own path).
    func cancelAutoAdvance() {
        guard !isStartingAdvance else { return }
        advanceTask?.cancel()
    }

    /// Waits for the auto-advance in flight (tests).
    func waitForAutoAdvance() async {
        await advanceTask?.value
    }

    // MARK: Helpers

    private func startEngine() {
        isFinishingLoad = false
        engine.setRate(Float(rate))
        engine.play()
        // The engine can refuse at once (the audio session won't activate): it has then cleared
        // the request and reported `.failed`.
        guard engine.isPlaybackRequested else { return }
        error = nil
        emit(.playbackStarted)
    }

    private func fail(_ error: PlaybackCoordinatorError, generation failed: Int) {
        guard failed == generation else { return }
        if failed == recoveryAttempt {
            // Recovery decides whether to try again or surface it; the kept audio session stays.
            recoveryAttemptError = error
            if phase != .loaded {
                // Seeks and jumps during the attempt (its `/play` or load) are where the next
                // one, or a retry, starts.
                let base = Self.clamp(pendingStartTime ?? unloadedPosition, to: unloadedDuration)
                unloadedPosition = Self.clamp(base + pendingJumpOffset, to: unloadedDuration)
                pendingStartTime = unloadedPosition
                if phase == .starting { phase = .unloaded }
            }
            pendingJumpOffset = 0
            return
        }
        pendingJumpOffset = 0
        self.error = error
        if phase == .starting { phase = .unloaded }
        releaseKeptAudioSession()
        emit(.failed(error))
    }

    // MARK: Recovery

    private func makeRecoveryHost() -> PlaybackRecoveryHost {
        PlaybackRecoveryHost(
            // A released coordinator's generation (-1) never matches, so its recovery stops.
            generation: { [weak self] in self?.generation ?? -1 },
            target: { [weak self] in self?.currentTime ?? 0 },
            reseek: { [weak self] target in
                guard let self else { return .superseded }
                return await engine.seek(to: engine.timeline?.clamp(target) ?? target)
            },
            play: { [weak self] in self?.startEngine() },
            rebuild: { [weak self] target, playing in
                await self?.rebuildForRecovery(at: target, playing: playing) ?? .superseded
            },
            refresh: { [weak self, sessions] in
                do {
                    try await sessions.refreshStreamAccess(replacing: self?.streamAccessToken)
                    return nil
                } catch let error as APIError {
                    // Reported as a session failure so an expired session leads to sign-in.
                    return .sessionStartFailed(error)
                } catch {
                    return .unexpected(String(describing: error))
                }
            },
            checkSession: { [weak self, sessions] in
                guard let id = self?.session?.id, self?.phase == .loaded else {
                    return PlaybackSessionCheck(status: .unknown)
                }
                return await sessions.sessionCheck(id: id)
            },
            giveUp: { [weak self] error in
                guard let self else { return }
                if phase == .loaded {
                    // Terminal: unload at the latest intended position, which releases the audio
                    // session; as after a failed load, the item stays and play retries it there.
                    let target = currentTime
                    saveLastPlayed()
                    tearDown(reason: .loadFailed)
                    pendingStartTime = target
                }
                self.error = error
                releaseKeptAudioSession()
                emit(.failed(error))
            })
    }

    /// A recovery rebuild: closes the session and starts a new one at `target` (an explicit
    /// start, so neither server progress nor auto-rewind moves it). Takes `generation + 1` at once.
    /// The path and setting now decide first, as for an auto-advance (no waiting): a block leaves
    /// the item as it is and recovery gives up with it, unless the user agreed to this item on a
    /// metered network.
    private func rebuildForRecovery(at target: Double, playing: Bool) async -> PlaybackRecoveryRebuild {
        guard let key = mediaKey, phase == .loaded || phase == .unloaded else { return .superseded }
        switch policy.currentStreamingDecision() {
        case .allowed: break
        case .askUser where meteredConsent == key: break
        case .askUser(let reason):
            // ``confirmMeteredStreaming()`` plays it again where recovery stopped.
            blockedPlay = (key, target)
            return .failed(.streamingNeedsConfirmation(reason, key: key), generation: generation)
        case .denied(let reason): return .failed(.streamingNotAllowed(reason, key: key), generation: generation)
        }
        let attempt = generation + 1
        recoveryAttempt = attempt
        recoveryAttemptError = nil
        // A call that held this item's play still holds it on the rebuilt one.
        if heldPlay?.generation == generation { heldPlay?.generation = attempt }
        defer {
            if recoveryAttempt == attempt {
                recoveryAttempt = nil
                recoveryAttemptError = nil
            }
        }
        await start(key: key, startTime: target, prepared: nil, playing: playing)
        guard generation == attempt else { return .superseded }
        if phase == .loaded { return .recovered(generation: attempt) }
        guard let error = recoveryAttemptError else { return .superseded }
        return .failed(error, generation: attempt)
    }

    /// The item that was to follow a switch failed or was abandoned: release the audio session the
    /// switch kept, so other apps' audio can resume.
    private func releaseKeptAudioSession() {
        guard keepsAudioSession, phase != .loaded else { return }
        keepsAudioSession = false
        engine.stop()
    }

    /// A streaming-policy block: the current item, and anything in flight for it, carries on.
    /// A confirmation block keeps the blocked play, with its `startTime`, for
    /// ``confirmMeteredStreaming()``.
    private func block(_ error: PlaybackCoordinatorError, startTime: Double? = nil) {
        if case .streamingNeedsConfirmation(_, let key) = error {
            blockedPlay = (key, startTime)
        } else {
            blockedPlay = nil
        }
        self.error = error
        emit(.failed(error))
    }

    /// Closes the current session (if any) and unloads the engine.
    private func tearDown(reason: SessionCloseReason) {
        closingPlaybackTime = confirmedPlaybackTime
        defer { closingPlaybackTime = nil }
        let wasLoaded = phase == .loaded
        awaitingSeekLanding = false
        rewindAwaitsLanding = false
        if wasLoaded {
            unloadedPosition = position
            unloadedDuration = engine.duration
        }
        resumeIntent += 1
        resumingIntent = nil
        isFinishingLoad = false
        if phase == .loaded || phase == .starting || keepsAudioSession {
            // Another item follows: the audio session stays active, so other apps' audio doesn't
            // resume in between. Anything else releases it.
            if reason == .itemChanged || reason == .restarted {
                keepsAudioSession = keepsAudioSession || engine.isAudioSessionActive
                engine.unload()
            } else {
                keepsAudioSession = false
                engine.stop()
            }
        }
        if phase != .idle { phase = .unloaded }
        if let session, let key = mediaKey {
            self.session = nil
            let closing = ClosingSession(
                sessionID: session.id, key: key, currentTime: unloadedPosition, duration: unloadedDuration,
                wasLoaded: wasLoaded, reason: reason)
            let handoff = wasLoaded ? finalCloseReport?(closing) : nil
            let operation = closeInBackground(sessionID: session.id, handoff: handoff, wasLoaded: wasLoaded)
            holdUntilSettled(key, operation: operation)
            emit(.sessionWillClose(closing))
        }
    }

    /// Holds `key` for its closing session (``MediaLeases/Holder/closingSession``) until everything
    /// the close sends or saves settles, whatever the outcome: its `/close`, the session's `/sync`
    /// in flight (which `/close` stops waiting for after ``closeWaitTimeout``), and its captured
    /// position write. Each resolves once its request returns or its save ends, so the hold ends.
    /// An account end resolves the close's receipt at once and cancels its task, but a `/close`
    /// already sent may still reach the server, so the hold also waits for that task to return.
    private func holdUntilSettled(_ key: MediaKey, operation: PlaybackCloseOperation) {
        guard let mediaLeases else { return }
        let lease = mediaLeases.acquire(key, for: .closingSession)
        let close = operation.task
        Task { @MainActor in
            _ = try? await operation.transport.wait()
            await close?.value
            _ = try? await operation.handoff?.sessionSync?.wait()
            if operation.wasLoaded { try? await operation.handoff?.waitForAudioPosition() }
            lease.release()
        }
    }

    @discardableResult
    private func closeInBackground(
        sessionID: String, report: PlaybackSyncReport? = nil,
        handoff: PlaybackCloseHandoff? = nil, wasLoaded: Bool = false
    ) -> PlaybackCloseOperation {
        let operation = PlaybackCloseOperation(sessionID: sessionID, wasLoaded: wasLoaded, handoff: handoff)
        guard closingSessionIDs.insert(sessionID).inserted else {
            // The server reused an ID whose close is pending: that close covers it, so this one sends
            // no `/close`. Its handoff's `/sync` in flight and position save are still its own, so the
            // returned operation keeps its media held until they settle (#368).
            operation.transport.resolve(.success(false))
            operation.dispatched.resolve(.success(()))
            return operation
        }
        closeOperations.append(operation)
        guard permitsCloseTransport else {
            operation.transport.resolve(.success(false))
            operation.dispatched.resolve(.success(()))
            return operation
        }
        let id = UUID()
        let sessions = self.sessions
        let sleep = self.sleep
        let task = Task { [weak self] in
            defer {
                self?.closeTasks[id] = nil
                self?.closeSentAt[id] = nil
                self?.closingSessionIDs.remove(sessionID)
                operation.task = nil
                operation.dispatched.resolve(.success(()))
            }
            // Account end cancels this owned task synchronously. Do not require the coordinator
            // to stay alive: ordinary stop has always allowed its captured close to outlive it.
            // The syncer's report in flight for this session returns first, within a limit (#337).
            try? await handoff?.waitForSessionSync(timeout: Self.closeWaitTimeout, sleep: sleep)
            guard !Task.isCancelled else {
                operation.transport.resolve(.success(false))
                return
            }
            self?.closeSentAt[id] = self?.now()
            operation.dispatched.resolve(.success(()))
            do {
                try await sessions.closeSession(id: sessionID, report: handoff?.report ?? report)
                operation.transport.resolve(.success(true))
            } catch {
                operation.transport.resolve(.failure(error))
                logger.info(
                    "Closing a playback session failed: \(Self.caseName(error), privacy: .public) \(String(describing: error), privacy: .private)"
                )
            }
        }
        closeTasks[id] = task
        operation.task = task
        return operation
    }

    /// Joins closes captured so far, without another callback or request. The deadline bounds
    /// this waiter, not the owned local write. A committed AUDIO POSITION permits fallback for
    /// failed/slow transport, never for a missing reporter or failed/pending position commit.
    /// Cancellation ends only this wait. Call synchronously `stop(reason:)` before awaiting.
    public func waitForClose(timeout: Duration = PlaybackCoordinator.closeWaitTimeout) async throws
        -> PlaybackCloseOutcome
    {
        let captured = closeOperations
        // Switch must also join cleanup of an issued /play or stream resolution. No-network
        // end deliberately suppresses that late cleanup instead of waiting for issued bytes.
        let openings = isRetired && permitsCloseTransport ? Array(pendingOpenings.values) : []
        func operations() -> [PlaybackCloseOperation] { openings.isEmpty ? captured : closeOperations }
        func outcome() throws -> PlaybackCloseOutcome {
            guard openings.allSatisfy({ $0.result != nil }) else { throw PlaybackCloseError.timedOut }
            return try PlaybackCloseOutcome(sessions: operations().map { try $0.outcome() })
        }
        let result = PlaybackCloseResult<PlaybackCloseOutcome>()
        let completion = Task {
            do {
                for opening in openings { try await opening.wait() }
                for operation in operations() {
                    if operation.wasLoaded {
                        guard let handoff = operation.handoff else {
                            throw PlaybackCloseError.missingReporter(sessionID: operation.sessionID)
                        }
                        do { try await handoff.waitForAudioPosition() } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            throw PlaybackCloseError.positionCommitFailed(
                                sessionID: operation.sessionID, description: String(describing: error))
                        }
                    }
                    _ = try? await operation.transport.wait()
                    try Task.checkCancellation()
                }
                result.resolve(Result { try outcome() })
            } catch {
                result.resolve(.failure(error))
            }
        }
        let sleep = self.sleep
        let timer = Task {
            await sleep(timeout)
            guard !Task.isCancelled else { return }
            result.resolve(Result { try outcome() })
        }
        defer {
            completion.cancel()
            timer.cancel()
        }
        return try await result.wait()
    }

    /// Waits for the closes in flight until each has had ``closeWaitTimeout`` since it was sent, so
    /// the server normally sees the old session closed before the next `/play`. A close that has
    /// already had its time (one hanging until the client's timeout) is not waited for again. The
    /// wait starts once each has been sent or suppressed, which its own wait for a report in flight
    /// bounds.
    private func waitForCloses() async {
        for operation in closeOperations where operation.task != nil {
            try? await operation.dispatched.wait()
        }
        let now = now()
        let (seconds, attoseconds) = Self.closeWaitTimeout.components
        let limit = Double(seconds) + Double(attoseconds) / 1e18
        let sleep = self.sleep
        var waits: [Task<Void, Never>] = []
        for (id, close) in closeTasks {
            // Clamped, so a clock set back never stretches the wait past the limit.
            let left = min(limit, limit - now.timeIntervalSince(closeSentAt[id] ?? now))
            guard left > 0 else { continue }
            // Each close races its own remaining time, so a newer close never extends an older one's.
            waits.append(
                Task {
                    let first = FirstFinish()
                    let timer = Task {
                        await sleep(.seconds(left))
                        first.finish()
                    }
                    Task {
                        await close.value
                        first.finish()
                    }
                    await first.wait()
                    timer.cancel()
                })
        }
        for wait in waits { await wait.value }
    }

    /// Takes this start's turn (see the class doc): the previous start has returned and the closes
    /// in flight have finished or timed out. Returns `nil`, having sent nothing, when a newer play,
    /// stop or restore superseded `generation` while it queued. The gate is released as this
    /// returns, before the caller registers the close of a stale session, so the next start's
    /// ``waitForCloses()`` sees it.
    private func startSessionSerially(
        itemID: String, episodeID: String?, generation: Int, prepared: PreparedNextItem?
    ) async throws -> StartedSession? {
        await startGate.acquire()
        defer { startGate.release() }
        guard self.generation == generation else { return nil }
        await waitForCloses()
        guard self.generation == generation else { return nil }
        // The next item changed during the wait (removed from the queue): no `/play`; the start
        // ends as a cancelled one, and the advance returns to the ended item (#338).
        if let prepared, nextItemProvider?.isStillNext(prepared.key) == false { throw CancellationError() }
        let sessions = self.sessions
        let progressStore = self.progressStore
        let key = MediaKey(
            serverConnectionID: sessions.serverConnectionID, libraryItemId: itemID, episodeId: episodeID)
        // A progress action on the item since this snapshot's preparation began (#368) changed its
        // progress: the prepared server progress could put back what the action discarded or reset,
        // so it's fetched again, as an unprepared start does.
        let prepared = prepared.flatMap {
            $0.actionGeneration == mediaLeases?.actionGeneration(of: key) ? $0 : nil
        }
        let task = Task { @MainActor in
            try Task.checkCancellation()
            if let prepared {
                // Prepared before the end: only `/play` is left.
                let session = try await sessions.startSession(itemID: itemID, episodeID: episodeID)
                return StartedSession(
                    session: session, serverProgress: prepared.serverProgress,
                    progressCapture: prepared.progressCapture)
            }
            let capture = try? await progressStore.captureStartProgress(for: key)
            try Task.checkCancellation()
            // After the closes: a restart must see the previous final report.
            async let serverProgress = Self.serverProgress(sessions, itemID: itemID, episodeID: episodeID)
            let session = try await sessions.startSession(itemID: itemID, episodeID: episodeID)
            return StartedSession(session: session, serverProgress: await serverProgress, progressCapture: capture)
        }
        startTask = task
        defer { startTask = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Resolution can refresh an access token. Own its cancellation independently of the caller,
    /// just like /play, while generation checks still discard uncooperative late completions.
    private func resolveStream(for session: PlaybackSession) async throws -> ResolvedStream {
        let id = UUID()
        let sessions = self.sessions
        let task = Task {
            try Task.checkCancellation()
            return try await sessions.resolveStream(for: session)
        }
        resolvingTasks[id] = task
        defer { resolvingTasks[id] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Waits for the background closes started so far (tests).
    func waitForPendingCloses() async {
        for task in closeTasks.values { await task.value }
    }

    /// The plays queued behind a session start (tests).
    var queuedSessionStarts: Int { startGate.waiterCount }

    private func makeSource(session: PlaybackSession, stream: ResolvedStream) throws(StreamResolutionError)
        -> AudioEngineSource
    {
        let timeline = PlaybackTimeline(session: session)
        var urls: [URL] = []
        var mimeTypes: [String?] = []
        for track in timeline.tracks {
            guard stream.urls.indices.contains(track.sourceIndex),
                stream.plan.tracks.indices.contains(track.sourceIndex)
            else { throw .trackCountMismatch }
            urls.append(stream.urls[track.sourceIndex])
            mimeTypes.append(stream.plan.tracks[track.sourceIndex].mimeType)
        }
        return AudioEngineSource(
            timeline: timeline, trackURLs: urls, trackMIMETypes: mimeTypes,
            networkAccess: NetworkAccess(policy: settings.streamingUsingCellular), headerTransport: stream.transport,
            prefersPreciseTiming: settings.enableMp3IndexSeeking, seekTolerance: stream.plan.kind == .hls ? 0.5 : 0)
    }

    private static func sessionError(_ error: any Error) -> PlaybackCoordinatorError {
        if let error = error as? APIError { return .sessionStartFailed(error) }
        return .unexpected(String(describing: error))
    }

    private static func streamError(_ error: any Error) -> PlaybackCoordinatorError {
        if let error = error as? StreamResolutionError { return .streamUnavailable(error) }
        // A token refresh that failed otherwise (offline, a 5xx) is a session failure, so recovery
        // retries a transient one.
        return sessionError(error)
    }

    private nonisolated static func serverProgress(
        _ sessions: any PlaybackSessionService, itemID: String, episodeID: String?
    ) async -> Result<MediaProgress?, any Error> {
        do {
            return .success(try await sessions.mediaProgress(itemID: itemID, episodeID: episodeID))
        } catch {
            return .failure(error)
        }
    }

    /// The error's case without associated values (which can carry server messages), for logs.
    private nonisolated static func caseName(_ error: any Error) -> String {
        String(String(describing: error).prefix { $0 != "(" })
    }

    /// Progress saved somewhere else since the record: newer and at a different position.
    private static func isFromElsewhere(_ candidate: ProgressCandidate, than record: LastPlayedRecord) -> Bool {
        guard let date = candidate.updatedAt else { return false }
        return date.timeIntervalSince(record.timestamp) > otherProgressDateTolerance
            && abs(candidate.currentTime - record.position) > otherProgressPositionTolerance
    }

    /// The unloaded position moved by jumps not yet applied, within the item. While a new item
    /// starts, its resume position (and duration) isn't known yet, so its jumps show once loaded.
    private var unloadedPositionAfterJumps: Double {
        if phase == .starting, isResolvingStart { return unloadedPosition }
        let base = Self.clamp(
            phase == .starting ? pendingStartTime ?? unloadedPosition : unloadedPosition, to: unloadedDuration)
        return Self.clamp(base + pendingJumpOffset, to: unloadedDuration)
    }

    /// Adds a clamped jump relative to a pending absolute seek, otherwise the unloaded position.
    ///
    /// While a restored item is still resolving its start, the jump is clamped against the saved
    /// record's position, not the position eventually resolved. For example, with a record at 3590
    /// of 3600, +30 keeps only +10, so a resolved 1000 becomes 1010. This is intentional: the
    /// position shown and the result stay consistent with what the user saw.
    private func addClampedJump(_ offset: Double) {
        // The load and catch-up seek use normalized positions, so offsets must use that same base.
        let base = Self.clamp(pendingStartTime ?? unloadedPosition, to: unloadedDuration)
        let position = Self.clamp(base + pendingJumpOffset, to: unloadedDuration)
        pendingJumpOffset = Self.clamp(position + offset, to: unloadedDuration) - base
    }

    /// `time` within `0...duration`, or only at 0 when the duration is unknown (0).
    private static func clamp(_ time: Double, to duration: Double) -> Double {
        let time = time.isFinite ? max(time, 0) : 0
        return duration > 0 ? min(time, duration) : time
    }

    private static func nonNegative(_ value: Double) -> Double {
        value.isFinite ? max(value, 0) : 0
    }

    private static func date(ms: Int) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }
}

extension PlaybackCoordinator: SleepTimerPlaybackControl {
    /// The loaded seek target, including an interrupted seek awaiting retry; observable independently
    /// of the ticking engine clock. No loaded media means no pending target.
    public var pendingSeekTarget: Double? { phase == .loaded ? engine.pendingSeekTarget : nil }

    /// Resumes loaded media after the timer's grace-period rewind. The timer already prepared the
    /// resume: do not call `willResume` again or seek (including AutoRewind). Returns whether playback is
    /// requested: already, or now; `false` without loaded media or when the engine refused at once.
    @discardableResult
    public func play() -> Bool {
        guard !isRetired, phase == .loaded else { return false }
        guard !engine.isPlaybackRequested else { return true }
        resumeIntent += 1
        resumingIntent = nil
        startEngine()
        return engine.isPlaybackRequested
    }

    public func setVolume(_ volume: Float) {
        engine.setVolume(volume)
    }
}

/// A session the server opened, with the progress fetched alongside it.
private struct StartedSession {
    let session: PlaybackSession
    let serverProgress: Result<MediaProgress?, any Error>
    let progressCapture: PlaybackStartProgressCapture?
}

/// Admits one session start at a time, in arrival order, with no timeout.
@MainActor
private final class StartGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiterCount: Int { waiters.count }

    /// Returns at once when the gate is free, else once every earlier waiter has released it.
    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the gate to the longest waiter, or frees it.
    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Resumes one waiter when the first of several racing tasks finishes.
private final class FirstFinish: Sendable {
    private let state = Mutex<(isDone: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isDone = state.withLock { state in
                if !state.isDone { state.waiter = continuation }
                return state.isDone
            }
            if isDone { continuation.resume() }
        }
    }

    func finish() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.isDone else { return nil }
            state.isDone = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }
}
