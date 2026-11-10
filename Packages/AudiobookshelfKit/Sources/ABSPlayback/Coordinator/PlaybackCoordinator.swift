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
    /// The current media (book or podcast episode); stable across sessions of the same media.
    public private(set) var mediaKey: MediaKey?
    /// The current server session: display metadata, chapters and the expanded library item.
    /// Its id is a capability (ADR 0007); never log it.
    public private(set) var session: PlaybackSession?
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
    /// hasn't landed (an interrupted one stays pending); else the position play will resume from.
    public var currentTime: Double { phase == .loaded ? position : unloadedPosition }
    public var duration: Double { phase == .loaded ? engine.duration : unloadedDuration }
    public var isPlaying: Bool { phase == .loaded && engine.state == .playing }
    public var isBuffering: Bool {
        switch phase {
        case .starting: true
        case .loaded: engine.state == .buffering || engine.state == .loading
        case .idle, .unloaded: false
        }
    }
    public var chapterIndex: Int? { timeline?.currentChapterIndex(at: currentTime) }
    public var chapter: Chapter? { timeline?.currentChapter(at: currentTime) }
    /// The current chapter's span, for chapter-relative times (`elapsed(at:)`, `remaining(at:)`).
    public var chapterRange: TimelineRange? {
        guard let timeline, chapterIndex != nil else { return nil }
        return timeline.progressRange(at: currentTime, chapterTrack: true)
    }
    public var chapterElapsed: Double? { chapterRange?.elapsed(at: currentTime) }
    public var chapterRemaining: Double? { chapterRange?.remaining(at: currentTime) }

    /// The P2-06b seam: the body of the final `/close` for a session that loaded (position and
    /// unsynced listening time). Not called for sessions that never loaded; `nil` closes without
    /// a body.
    @ObservationIgnored public var finalCloseReport: (@MainActor (ClosingSession) -> PlaybackSyncReport?)?
    /// Called once before playback starts or resumes, before the resume seek; returns extra
    /// seconds to rewind (the sleep timer's `playbackWillStart`, P2-08). The extra rewind is
    /// ignored for an explicit start time and for a restart from the end.
    @ObservationIgnored public var willResume: (@MainActor () -> TimeInterval)?

    // MARK: Dependencies

    @ObservationIgnored private let engine: any AudioEngineProtocol
    @ObservationIgnored private let sessions: any PlaybackSessionService
    @ObservationIgnored private let progressStore: any LocalProgressReading
    @ObservationIgnored private let settings: any PlaybackSettingsProviding
    @ObservationIgnored private let policy: any StreamingPolicyChecking
    @ObservationIgnored private let lastPlayedStore: any LastPlayedStoring
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void

    // MARK: Bookkeeping

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var playWhenLoaded = true
    /// A position chosen while starting or unloaded (a seek, or a play with a start time).
    @ObservationIgnored private var pendingStartTime: Double?
    @ObservationIgnored private var policyCheck = 0
    /// When playback was last seen playing; drives auto-rewind on resume.
    @ObservationIgnored private var lastPlayedAt: Date?
    @ObservationIgnored private var lastPlayedSavedAt: Date?
    /// The media played to its end; the next play starts again from 0.
    @ObservationIgnored private var reachedEnd = false
    /// The load's initial seek was interrupted and hasn't landed: its `didSeek` is still owed.
    @ObservationIgnored private var awaitingInitialLanding = false
    /// Bumped by every resume and pause; a resume plays only if it's still the latest.
    @ObservationIgnored private var resumeIntent = 0
    @ObservationIgnored private var resumingIntent: Int?
    @ObservationIgnored private var closingSessionIDs: Set<String> = []
    @ObservationIgnored private var closeTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let startGate = StartGate()
    @ObservationIgnored private var observers: [PlaybackObserverToken: @MainActor (PlaybackCoordinatorEvent) -> Void] =
        [:]
    @ObservationIgnored private var queuedEvents: [PlaybackCoordinatorEvent] = []
    @ObservationIgnored private var isEmitting = false

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

    /// - Parameter sleep: Times the wait for closes in flight (tests replace it).
    public init(
        engine: any AudioEngineProtocol, sessions: any PlaybackSessionService, progressStore: any LocalProgressReading,
        settings: any PlaybackSettingsProviding, policy: any StreamingPolicyChecking,
        lastPlayedStore: any LastPlayedStoring, now: @escaping @Sendable () -> Date = { .now },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
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
        let key = MediaKey(
            serverConnectionID: sessions.serverConnectionID, libraryItemId: itemID, episodeId: episodeID)
        policyCheck += 1
        let check = policyCheck
        pendingPlayKey = nil
        if key == mediaKey {
            switch phase {
            case .loaded:
                return await resumeLoaded(rewindingBy: nil, startingAt: startTime)
            case .starting:
                playWhenLoaded = true
                if let startTime { pendingStartTime = startTime }
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

        generation += 1
        let current = generation
        let restarting = key == mediaKey
        // A seek while unloaded (restored, or a failed start's start time) is an explicit start,
        // unless progress from elsewhere turns out newer than the last-played record.
        let unloadedSeek = restarting && phase == .unloaded && startTime == nil ? pendingStartTime : nil
        tearDown(reason: restarting ? .restarted : .itemChanged)
        guard current == generation else { return }
        error = nil
        pendingStartTime = startTime ?? unloadedSeek
        reachedEnd = false
        playWhenLoaded = true
        phase = .starting
        if !restarting {
            mediaKey = key
            lastPlayedAt = nil
            restoredRecord = nil
            unloadedPosition = 0
            unloadedDuration = 0
            emit(.itemChanged(key))
        }
        guard current == generation else { return }

        let started: StartedSession
        do {
            guard
                let result = try await startSessionSerially(
                    itemID: itemID, episodeID: episodeID, generation: current)
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
            let stream = try await sessions.resolveStream(for: session)
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
        unloadedDuration = source.timeline.duration
        emit(.sessionStarted(sessionID: session.id, key: key))

        let local = try? await progressStore.progress(for: key)
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
            // Otherwise the position, date and flag all come from the fetched progress: `/play` may
            // have captured an older position than the fetch returned.
            candidates.append(
                ProgressCandidate(
                    currentTime: progress.currentTime, updatedAt: progress.lastUpdate.map(Self.date(ms:)),
                    isFinished: progress.isFinished))
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
        let plannedStart = pendingStartTime
        var explicitStart = plannedStart
        if let unloadedSeek, explicitStart == unloadedSeek, let record,
            candidates.contains(where: { Self.isFromElsewhere($0, than: record) })
        {
            explicitStart = nil
        }
        let extra = playWhenLoaded ? Self.nonNegative(willResume?() ?? 0) : 0
        let resumeTime = ResumePosition.startTime(
            explicit: explicitStart, candidates: candidates, duration: source.timeline.duration, now: now(),
            autoRewind: !settings.disableAutoRewind)
        let target = explicitStart == nil ? max(resumeTime - extra, 0) : resumeTime

        engine.setRate(Float(rate))
        unloadedPosition = target
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
        phase = .loaded
        restoredRecord = nil
        lastPlayedAt = nil
        let intent = resumeIntent
        let pending = pendingStartTime
        pendingStartTime = nil
        if let pending, pending != plannedStart {
            // A seek while loading.
            await engine.seek(to: engine.timeline?.clamp(pending) ?? pending)
            guard current == generation, phase == .loaded else { return }
        }
        // An interrupted initial seek stays pending with the engine paused at 0: `.loaded` carries
        // its target, and `.didSeek` waits for the landing (see `handle(_:)`).
        let landed = engine.pendingSeekTarget == nil
        awaitingInitialLanding = !landed
        emit(.loaded(time: position))
        if landed { emit(.didSeek(time: engine.currentTime)) }
        guard current == generation, phase == .loaded else { return }
        saveLastPlayed()
        // A pause or resume during the seek above takes over.
        if playWhenLoaded, intent == resumeIntent { startEngine() }
    }

    /// Plays the current item: resumes a loaded one (rewinding by `seconds`, or by ``AutoRewind``
    /// for the time since it last played), or starts a session for a restored or failed one.
    public func resume(rewindingBy seconds: Double? = nil) async {
        guard let key = mediaKey else { return }
        switch phase {
        case .idle: return
        case .starting: playWhenLoaded = true
        case .unloaded: await play(itemID: key.libraryItemId, episodeID: key.episodeId)
        case .loaded: await resumeLoaded(rewindingBy: seconds, startingAt: nil)
        }
    }

    /// The single place loaded media resumes. In order: ``willResume``; one awaited seek (to
    /// `startTime`, else exactly to the target of an interrupted seek still pending, else to 0
    /// after the end, else back by `seconds` or ``AutoRewind``), which emits
    /// ``PlaybackCoordinatorEvent/didSeek(time:)`` with where it landed; then play. A pause during
    /// the seek cancels the play, and a resume while one is in flight is ignored (a `startTime`
    /// replaces it). While already playing, a `startTime` is only a seek.
    private func resumeLoaded(rewindingBy seconds: Double?, startingAt startTime: Double?) async {
        let time = engine.currentTime
        let atEnd = reachedEnd || engine.state == .ended
        if let startTime, engine.isPlaybackRequested, !atEnd, resumingIntent == nil {
            // Already playing: just move.
            await seek(to: startTime)
            return
        }
        guard startTime != nil || (resumingIntent == nil && (atEnd || !engine.isPlaybackRequested)) else { return }
        resumeIntent += 1
        let intent = resumeIntent
        let current = generation
        resumingIntent = intent
        defer { if resumingIntent == intent { resumingIntent = nil } }

        let extra = Self.nonNegative(willResume?() ?? 0)
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

    public func pause() {
        switch phase {
        case .starting: playWhenLoaded = false
        case .loaded:
            resumeIntent += 1
            resumingIntent = nil
            guard engine.isPlaybackRequested else { return }
            engine.pause()
            lastPlayedAt = now()
            saveLastPlayed()
            emit(.paused(time: position))
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
            guard await engine.seek(to: target) == .completed, current == generation, phase == .loaded else {
                return nil
            }
            reachedEnd = false
            awaitingInitialLanding = false
            let landed = engine.currentTime
            emit(.didSeek(time: landed))
            saveLastPlayed()
            return landed
        case .unloaded:
            let finite = time.isFinite ? max(time, 0) : 0
            unloadedPosition = unloadedDuration > 0 ? min(finite, unloadedDuration) : finite
            pendingStartTime = unloadedPosition
            return unloadedPosition
        case .starting:
            pendingStartTime = time
            return nil
        case .idle:
            return nil
        }
    }

    /// Sets and saves the playback rate. Rates the settings reject are ignored.
    public func setRate(_ rate: Double) {
        settings.playbackRate = rate
        engine.setRate(Float(self.rate))
    }

    /// Stops playback, closes the session and forgets the item, so it isn't restored at launch.
    public func stop() {
        generation += 1
        pendingPlayKey = nil
        let hadItem = mediaKey != nil
        tearDown(reason: .stopped)
        mediaKey = nil
        error = nil
        restoredRecord = nil
        pendingStartTime = nil
        reachedEnd = false
        unloadedPosition = 0
        unloadedDuration = 0
        phase = .idle
        lastPlayedStore.clear()
        if hadItem { emit(.itemChanged(nil)) }
    }

    /// Publishes the last-played item for this connection, paused at its saved position, with
    /// its display metadata in ``restoredRecord``, without starting a session or loading the
    /// engine. Returns whether an item was restored.
    @discardableResult
    public func restoreLastPlayed() -> Bool {
        guard phase == .idle, let record = lastPlayedStore.load(),
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

    /// Saves the loaded item's position as the last-played record. Call when the app moves to
    /// the background; pauses, seeks, loads and the end save it already.
    public func saveLastPlayed() {
        guard let key = mediaKey, phase == .loaded else { return }
        let date = now()
        lastPlayedSavedAt = date
        lastPlayedStore.save(
            LastPlayedRecord(
                serverConnectionID: key.serverConnectionID, libraryItemID: key.libraryItemId,
                episodeID: key.episodeId, position: currentTime, duration: duration > 0 ? duration : nil,
                timestamp: date, isFinished: reachedEnd, title: session?.displayTitle, author: session?.displayAuthor,
                coverPath: session?.coverPath, chapterTitle: chapter?.title))
    }

    // MARK: Engine events

    private func handle(_ event: AudioEngineEvent) {
        guard phase == .loaded else { return }
        switch event {
        case .tick(let time):
            if awaitingInitialLanding, engine.pendingSeekTarget == nil {
                // The interrupted initial seek has landed: the engine retried it as playback started.
                awaitingInitialLanding = false
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
            emit(.ended)
        case .failed(let failure):
            // Recovery (ADR 0007 retries, rebuilds) hooks in here; for now the failure is surfaced.
            let error = PlaybackCoordinatorError(engineError: failure)
            self.error = error
            emit(.failed(error))
        }
    }

    // MARK: Helpers

    private func startEngine() {
        engine.setRate(Float(rate))
        engine.play()
        // The engine can refuse at once (the audio session won't activate): it has then cleared
        // the request and reported `.failed`.
        guard engine.isPlaybackRequested else { return }
        emit(.playbackStarted)
    }

    private func fail(_ error: PlaybackCoordinatorError, generation failed: Int) {
        guard failed == generation else { return }
        self.error = error
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
        let wasLoaded = phase == .loaded
        awaitingInitialLanding = false
        if wasLoaded {
            unloadedPosition = position
            unloadedDuration = engine.duration
        }
        resumeIntent += 1
        resumingIntent = nil
        if phase == .loaded || phase == .starting { engine.stop() }
        if phase != .idle { phase = .unloaded }
        if let session, let key = mediaKey {
            self.session = nil
            let closing = ClosingSession(
                sessionID: session.id, key: key, currentTime: unloadedPosition, duration: unloadedDuration,
                wasLoaded: wasLoaded, reason: reason)
            let report = wasLoaded ? finalCloseReport?(closing) : nil
            closeInBackground(sessionID: session.id, report: report)
            emit(.sessionWillClose(closing))
        }
    }

    private func closeInBackground(sessionID: String, report: PlaybackSyncReport?) {
        guard closingSessionIDs.insert(sessionID).inserted else { return }
        let id = UUID()
        let sessions = self.sessions
        closeTasks[id] = Task { [weak self] in
            do {
                try await sessions.closeSession(id: sessionID, report: report)
            } catch {
                logger.info(
                    "Closing a playback session failed: \(Self.caseName(error), privacy: .public) \(String(describing: error), privacy: .private)"
                )
            }
            self?.closeTasks[id] = nil
            self?.closingSessionIDs.remove(sessionID)
        }
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
        itemID: String, episodeID: String?, generation: Int
    ) async throws -> StartedSession? {
        await startGate.acquire()
        defer { startGate.release() }
        guard self.generation == generation else { return nil }
        await waitForCloses()
        guard self.generation == generation else { return nil }
        let sessions = self.sessions
        // Read only, but after the closes: a restart must see the previous session's final report.
        async let serverProgress = Self.serverProgress(sessions, itemID: itemID, episodeID: episodeID)
        let session = try await sessions.startSession(itemID: itemID, episodeID: episodeID)
        return StartedSession(session: session, serverProgress: await serverProgress)
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

    private static func nonNegative(_ value: Double) -> Double {
        value.isFinite ? max(value, 0) : 0
    }

    private static func date(ms: Int) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }
}

/// A session the server opened, with the progress fetched alongside it.
private struct StartedSession {
    let session: PlaybackSession
    let serverProgress: Result<MediaProgress?, any Error>
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
