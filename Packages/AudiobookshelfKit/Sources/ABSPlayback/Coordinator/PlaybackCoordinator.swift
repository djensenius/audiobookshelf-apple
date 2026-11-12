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
///   old session closed first; a slow or failed close never blocks it. Closes are best effort;
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
    /// ignored for an explicit start time and for a restart from the end.
    @ObservationIgnored public var willResume: (@MainActor () -> TimeInterval)?
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
    /// Bumped by every resume and pause; a resume plays only if it's still the latest.
    @ObservationIgnored private var resumeIntent = 0
    private var resumingIntent: Int?
    @ObservationIgnored private var closingSessionIDs: Set<String> = []
    @ObservationIgnored private var closeTasks: [UUID: Task<Void, Never>] = [:]
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
    public init(
        engine: any AudioEngineProtocol, sessions: any PlaybackSessionService, progressStore: any LocalProgressReading,
        settings: any PlaybackSettingsProviding, policy: any StreamingPolicyChecking,
        lastPlayedStore: any LastPlayedStoring, now: @escaping @Sendable () -> Date = { .now },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        backgroundActivity: any BackgroundActivity = NoBackgroundActivity()
    ) {
        self.backgroundActivity = backgroundActivity
        self.engine = engine
        self.sessions = sessions
        self.progressStore = progressStore
        self.settings = settings
        self.policy = policy
        self.lastPlayedStore = lastPlayedStore
        self.now = now
        self.sleep = sleep
        engine.onEvent = { [weak self] event in self?.handle(event) }
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
        if key == mediaKey {
            switch phase {
            case .loaded where isFinishingLoad:
                // `play()` for this item starts the engine after its catch-up seek; a start time
                // retargets that seek (a later seek replaces it).
                playWhenLoaded = true
                if let startTime { await seek(to: startTime) }
                return
            case .loaded:
                return await resumeLoaded(rewindingBy: nil, startingAt: startTime)
            case .starting:
                playWhenLoaded = true
                if let startTime {
                    pendingStartTime = startTime
                    pendingJumpOffset = 0
                }
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
        case .askUser(let reason): return block(.streamingNeedsConfirmation(reason, key: key))
        case .denied(let reason): return block(.streamingNotAllowed(reason, key: key))
        }
        await start(key: key, startTime: startTime, prepared: nil)
    }

    /// Everything after a play passed the streaming policy. A `prepared` start (an auto-advance)
    /// reuses its server progress instead of fetching it.
    private func start(key: MediaKey, startTime: Double?, prepared: PreparedNextItem?) async {
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
        playWhenLoaded = true
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
            return
        } catch {
            return fail(Self.sessionError(error), generation: current)
        }
        let session = started.session
        guard current == generation else { return closeInBackground(sessionID: session.id, report: nil) }

        let source: AudioEngineSource
        do {
            let stream = try await resolveStream(for: session)
            source = try makeSource(session: session, stream: stream)
        } catch {
            closeInBackground(sessionID: session.id, report: nil)
            // A cancelled caller abandons the start; that isn't a failure.
            if error is CancellationError {
                if current == generation, phase == .starting { phase = .unloaded }
                return
            }
            return fail(Self.streamError(error), generation: current)
        }
        guard current == generation else { return closeInBackground(sessionID: session.id, report: nil) }
        // From here the coordinator owns the session: whoever replaces it closes it.
        self.session = session
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
        if !Task.isCancelled, localReadSucceeded, let capture = started.progressCapture,
            case .success(let progress?) = server
        {
            _ = try? await progressStore.applyStartProgress(progress, captured: capture)
        }
        guard current == generation else { return }
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
        var seekTarget: Double?
        if let pending, pending != plannedStart {
            // A seek while loading: normalize before adding jumps, just as the initial load does.
            seekTarget = Self.clamp(pending, to: unloadedDuration)
        }
        // Use the requested resume anchor (or newer seek), not the engine's gap-snapped landing.
        if jumpOffset != 0 { seekTarget = (seekTarget ?? target) + jumpOffset }
        if let seekTarget {
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
        case .starting: playWhenLoaded = true
        case .unloaded: await play(itemID: key.libraryItemId, episodeID: key.episodeId)
        case .loaded where isFinishingLoad: playWhenLoaded = true
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
        if let startTime {
            target = startTime
        } else if let pending = engine.pendingSeekTarget {
            // The user's interrupted seek is where playback goes: not rewound from the old
            // position, nor replaced by the restart from the end.
            target = pending
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
        }
        if let target {
            await seek(to: target)
        }
        guard intent == resumeIntent, current == generation, phase == .loaded else { return }
        startEngine()
    }

    /// Pauses, and cancels a play waiting on its streaming-policy check (``pendingPlayKey``).
    /// Always emits `paused`, even when already paused, so a sleep timer's pending resume can be cancelled.
    public func pause() {
        defer { emit(.paused(time: currentTime)) }
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
    public func seek(to time: Double) async -> Double? {
        switch phase {
        case .loaded:
            let current = generation
            let target = engine.timeline?.clamp(time) ?? max(time, 0)
            reachedEnd = false
            awaitingSeekLanding = true
            let result = await engine.seek(to: target)
            guard current == generation, phase == .loaded else { return nil }
            guard result == .completed else {
                awaitingSeekLanding = isFinishingLoad || engine.pendingSeekTarget != nil
                return nil
            }
            let landed = engine.currentTime
            if awaitingSeekLanding, !isFinishingLoad {
                awaitingSeekLanding = false
                emit(.didSeek(time: landed))
                saveLastPlayed()
            }
            return landed
        case .unloaded:
            let finite = time.isFinite ? max(time, 0) : 0
            unloadedPosition = unloadedDuration > 0 ? min(finite, unloadedDuration) : finite
            pendingStartTime = unloadedPosition
            pendingJumpOffset = 0
            return unloadedPosition
        case .starting:
            pendingStartTime = time
            pendingJumpOffset = 0
            return nil
        case .idle:
            return nil
        }
    }

    /// Jumps by `offset` seconds (negative jumps back), clamped to the item, and returns where
    /// playback landed (`nil` as for ``seek(to:)``). Loaded, the jump is relative to the latest
    /// seek's target while one is in flight, so rapid jumps add up. While starting, jumps add up and
    /// apply after the resume position is resolved, so they never replace it. Unloaded, a jump
    /// moves a chosen position (after a ``seek(to:)``), or else moves the position shown and
    /// applies after the resume position is resolved, keeping the progress-from-elsewhere rule.
    @discardableResult
    public func jump(by offset: Double) async -> Double? {
        guard offset.isFinite, offset != 0 else { return nil }
        switch phase {
        case .loaded:
            return await seek(to: (engine.pendingSeekTarget ?? engine.currentTime) + offset)
        case .starting:
            // Clamped like an unloaded jump once the item's duration is known.
            if isResolvingStart || unloadedDuration == 0 { pendingJumpOffset += offset } else { addClampedJump(offset) }
            return nil
        case .unloaded:
            if let pendingStartTime {
                return await seek(to: Self.clamp(pendingStartTime, to: unloadedDuration) + offset)
            }
            addClampedJump(offset)
            return unloadedPositionAfterJumps
        case .idle:
            return nil
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
        case .loaded: return engine.isPlaybackRequested || resumingIntent != nil
        case .idle, .unloaded: return false
        }
    }

    /// Sets and saves the playback rate. Rates the settings reject are ignored.
    public func setRate(_ rate: Double) {
        settings.playbackRate = rate
        engine.setRate(Float(self.rate))
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
    /// engine. Returns whether an item was restored.
    @discardableResult
    public func restoreLastPlayed() -> Bool {
        guard !isRetired, phase == .idle, let record = lastPlayedStore.load(),
            record.serverConnectionID == sessions.serverConnectionID
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
        guard phase == .loaded else { return }
        switch event {
        case .tick(let time):
            // An internal engine.play() retry has no awaited coordinator seek completion.
            // Its owed didSeek waits for the first tick with no pending target after loaded;
            // clearing the flag before emitting prevents later ticks from announcing it again.
            if awaitingSeekLanding, !isFinishingLoad, engine.pendingSeekTarget == nil {
                awaitingSeekLanding = false
                emit(.didSeek(time: engine.currentTime))
                guard phase == .loaded else { return }
                saveLastPlayed()
            }
            if engine.state == .playing {
                let date = now()
                lastPlayedAt = date
                if lastPlayedSavedAt.map({ date.timeIntervalSince($0) >= Self.lastPlayedSaveInterval }) ?? true {
                    saveLastPlayed()
                }
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
        case .failed(let failure):
            // Recovery (ADR 0007 retries, rebuilds) hooks in here; for now the failure is surfaced.
            let error = PlaybackCoordinatorError(engineError: failure)
            self.error = error
            emit(.failed(error))
        }
    }

    // MARK: Auto-advance

    /// What a start fetches before `/play` (the streaming decision and server progress, after
    /// capturing local progress as a start does), done ahead of time for the item to follow.
    func prepareStart(for key: MediaKey) async -> PreparedNextItem {
        let capture = try? await progressStore.captureStartProgress(for: key)
        let progress = await Self.serverProgress(sessions, itemID: key.libraryItemId, episodeID: key.episodeId)
        let decision = await policy.streamingDecision()
        return PreparedNextItem(key: key, decision: decision, serverProgress: progress, progressCapture: capture)
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
        // Nobody can agree to a metered network at the lock screen; the item stays queued.
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
        self.error = error
        pendingJumpOffset = 0
        if phase == .starting { phase = .unloaded }
        emit(.failed(error))
    }

    /// A streaming-policy block: the current item, and anything in flight for it, carries on.
    private func block(_ error: PlaybackCoordinatorError) {
        self.error = error
        emit(.failed(error))
    }

    /// Closes the current session (if any) and unloads the engine.
    private func tearDown(reason: SessionCloseReason) {
        closingPlaybackTime = confirmedPlaybackTime
        defer { closingPlaybackTime = nil }
        let wasLoaded = phase == .loaded
        awaitingSeekLanding = false
        if wasLoaded {
            unloadedPosition = position
            unloadedDuration = engine.duration
        }
        resumeIntent += 1
        resumingIntent = nil
        isFinishingLoad = false
        if phase == .loaded || phase == .starting { engine.stop() }
        if phase != .idle { phase = .unloaded }
        if let session, let key = mediaKey {
            self.session = nil
            let closing = ClosingSession(
                sessionID: session.id, key: key, currentTime: unloadedPosition, duration: unloadedDuration,
                wasLoaded: wasLoaded, reason: reason)
            let handoff = wasLoaded ? finalCloseReport?(closing) : nil
            closeInBackground(sessionID: session.id, handoff: handoff, wasLoaded: wasLoaded)
            emit(.sessionWillClose(closing))
        }
    }

    private func closeInBackground(
        sessionID: String, report: PlaybackSyncReport? = nil,
        handoff: PlaybackCloseHandoff? = nil, wasLoaded: Bool = false
    ) {
        guard closingSessionIDs.insert(sessionID).inserted else { return }
        let operation = PlaybackCloseOperation(sessionID: sessionID, wasLoaded: wasLoaded, handoff: handoff)
        closeOperations.append(operation)
        guard permitsCloseTransport else {
            operation.transport.resolve(.success(false))
            return
        }
        let id = UUID()
        let sessions = self.sessions
        let sleep = self.sleep
        let task = Task { [weak self] in
            defer {
                self?.closeTasks[id] = nil
                self?.closingSessionIDs.remove(sessionID)
                operation.task = nil
            }
            // Account end cancels this owned task synchronously. Do not require the coordinator
            // to stay alive: ordinary stop has always allowed its captured close to outlive it.
            // The syncer's report in flight for this session returns first, within a limit (#337).
            try? await handoff?.waitForSessionSync(timeout: Self.closeWaitTimeout, sleep: sleep)
            guard !Task.isCancelled else {
                operation.transport.resolve(.success(false))
                return
            }
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

    /// Waits up to ``closeWaitTimeout`` for the closes in flight, so the server normally sees
    /// the old session closed before the next `/play`.
    private func waitForCloses() async {
        let closes = Array(closeTasks.values)
        guard !closes.isEmpty else { return }
        let first = FirstFinish()
        let sleep = self.sleep
        let timer = Task {
            await sleep(Self.closeWaitTimeout)
            first.finish()
        }
        Task {
            for close in closes { await close.value }
            first.finish()
        }
        await first.wait()
        timer.cancel()
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
            networkAccess: NetworkAccess(policy: settings.streamingUsingCellular),
            prefersPreciseTiming: settings.enableMp3IndexSeeking, seekTolerance: stream.plan.kind == .hls ? 0.5 : 0)
    }

    private static func sessionError(_ error: any Error) -> PlaybackCoordinatorError {
        if let error = error as? APIError { return .sessionStartFailed(error) }
        return .unexpected(String(describing: error))
    }

    private static func streamError(_ error: any Error) -> PlaybackCoordinatorError {
        if let error = error as? StreamResolutionError { return .streamUnavailable(error) }
        return .unexpected(String(describing: error))
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
    /// resume: do not call `willResume` again or seek (including AutoRewind).
    public func play() {
        guard !isRetired, phase == .loaded, !engine.isPlaybackRequested else { return }
        resumeIntent += 1
        resumingIntent = nil
        startEngine()
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
