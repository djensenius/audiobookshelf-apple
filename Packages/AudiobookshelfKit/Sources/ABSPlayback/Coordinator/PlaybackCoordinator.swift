import ABSAPI
import ABSCore
import ABSData
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "PlaybackCoordinator")

/// Turns "play this" into playback, independent of any scene: checks the streaming policy, opens a
/// server session, loads the engine at the resume position and applies the saved rate. Closes the
/// session when playback stops or the item changes, and restores the last item paused at launch.
///
/// - **Races.** Every ``play(itemID:episodeID:startTime:allowingMeteredNetwork:)``, ``stop()`` and
///   ``restoreLastPlayed()`` takes a new generation. A continuation from an older generation (a
///   session start or engine load finishing late) is dropped, and a session it opened is closed.
/// - **Closing.** A session is owned by exactly one place: the start continuation until it becomes
///   current, then the coordinator. Whoever drops it closes it once, in the background, so a slow
///   or failed close never delays the next play. Closes are best effort; P2-06b's final report is
///   plugged in through ``finalCloseReport``.
/// - **Restore is lazy.** ``restoreLastPlayed()`` only publishes the item and position from the
///   ``LastPlayedRecord``; the session starts and the engine loads on the first ``resume(rewindingBy:)``
///   or play, so opening the app never creates a server session.
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
    /// The saved playback rate, applied to every load.
    public private(set) var rate: Double
    private var unloadedPosition: Double = 0
    private var unloadedDuration: Double = 0

    public var timeline: PlaybackTimeline? { phase == .loaded ? engine.timeline : nil }
    /// Global seconds: the engine's while loaded, else the position play will resume from.
    public var currentTime: Double { phase == .loaded ? engine.currentTime : unloadedPosition }
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

    /// The P2-06b seam: the body of the final `/close` for a session (position and unsynced
    /// listening time). `nil`, the default, closes without a body.
    @ObservationIgnored public var finalCloseReport: (@MainActor (ClosingSession) -> PlaybackSyncReport?)?
    /// Called once before playback starts or resumes, before the resume seek; returns extra
    /// seconds to rewind (the sleep timer's `playbackWillStart`, P2-08). The extra rewind is
    /// ignored when a play has an explicit start time.
    @ObservationIgnored public var willResume: (@MainActor () -> TimeInterval)?

    // MARK: Dependencies

    @ObservationIgnored private let engine: any AudioEngineProtocol
    @ObservationIgnored private let sessions: any PlaybackSessionService
    @ObservationIgnored private let progressStore: any LocalProgressReading
    @ObservationIgnored private let settings: any PlaybackSettingsProviding
    @ObservationIgnored private let policy: any StreamingPolicyChecking
    @ObservationIgnored private let lastPlayedStore: any LastPlayedStoring
    @ObservationIgnored private let now: @Sendable () -> Date

    // MARK: Bookkeeping

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var playWhenLoaded = true
    /// An explicit position chosen while unloaded (a seek before the first play).
    @ObservationIgnored private var pendingStartTime: Double?
    /// When playback was last seen playing; drives auto-rewind on resume.
    @ObservationIgnored private var lastPlayedAt: Date?
    @ObservationIgnored private var lastPlayedSavedAt: Date?
    @ObservationIgnored private var closingSessionIDs: Set<String> = []
    @ObservationIgnored private var closeTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var observers: [PlaybackObserverToken: @MainActor (PlaybackCoordinatorEvent) -> Void] =
        [:]

    /// The last-played record is saved at most this often from time updates.
    static let lastPlayedSaveInterval: TimeInterval = 15

    public init(
        engine: any AudioEngineProtocol, sessions: any PlaybackSessionService, progressStore: any LocalProgressReading,
        settings: any PlaybackSettingsProviding, policy: any StreamingPolicyChecking,
        lastPlayedStore: any LastPlayedStoring, now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.engine = engine
        self.sessions = sessions
        self.progressStore = progressStore
        self.settings = settings
        self.policy = policy
        self.lastPlayedStore = lastPlayedStore
        self.now = now
        rate = settings.playbackRate
        engine.onEvent = { [weak self] event in self?.handle(event) }
    }

    // MARK: Observers

    /// Adds an observer for ``PlaybackCoordinatorEvent``s; events are delivered synchronously.
    @discardableResult
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
        for handler in observers.values { handler(event) }
    }

    // MARK: Commands

    /// Plays an item or podcast episode from the server.
    ///
    /// The same media, already loaded and with no `startTime`, just resumes. Otherwise the current
    /// session is closed and a new one started at `startTime`, or else at the newest of server
    /// progress, local progress and the last-played record, rewound by ``AutoRewind``.
    /// - Parameter allowingMeteredNetwork: The user agreed to stream on a metered network after
    ///   ``PlaybackCoordinatorError/streamingNeedsConfirmation(_:)``. Never overrides "never".
    public func play(
        itemID: String, episodeID: String? = nil, startTime: Double? = nil, allowingMeteredNetwork: Bool = false
    ) async {
        let key = MediaKey(
            serverConnectionID: sessions.serverConnectionID, libraryItemId: itemID, episodeId: episodeID)
        if key == mediaKey, startTime == nil {
            switch phase {
            case .loaded:
                await resume()
                return
            case .starting:
                playWhenLoaded = true
                return
            case .idle, .unloaded:
                break
            }
        }
        let explicitStart = startTime ?? (key == mediaKey && phase == .unloaded ? pendingStartTime : nil)

        generation += 1
        let current = generation
        if key != mediaKey {
            tearDown(reason: .itemChanged)
            mediaKey = key
            unloadedPosition = 0
            unloadedDuration = 0
            emit(.itemChanged(key))
        } else {
            tearDown(reason: .itemChanged)
        }
        error = nil
        pendingStartTime = nil
        lastPlayedAt = nil
        playWhenLoaded = true
        phase = .starting

        switch await policy.streamingDecision() {
        case .allowed: break
        case .askUser(let reason) where allowingMeteredNetwork:
            logger.info("Streaming on a metered path (\(String(describing: reason)))")
        case .askUser(let reason): return fail(.streamingNeedsConfirmation(reason), generation: current)
        case .denied(let reason): return fail(.streamingNotAllowed(reason), generation: current)
        }
        guard current == generation else { return }

        let sessions = self.sessions
        async let serverProgress = try? sessions.mediaProgress(itemID: itemID, episodeID: episodeID)
        let session: PlaybackSession
        do {
            session = try await sessions.startSession(itemID: itemID, episodeID: episodeID)
        } catch {
            return fail(Self.sessionError(error), generation: current)
        }
        guard current == generation else { return closeInBackground(sessionID: session.id, report: nil) }

        let source: AudioEngineSource
        do {
            let stream = try await sessions.resolveStream(for: session)
            source = try makeSource(session: session, stream: stream)
        } catch {
            closeInBackground(sessionID: session.id, report: nil)
            return fail(Self.streamError(error), generation: current)
        }
        guard current == generation else { return closeInBackground(sessionID: session.id, report: nil) }
        // From here the coordinator owns the session: whoever replaces it closes it.
        self.session = session
        unloadedDuration = source.timeline.duration
        emit(.sessionStarted(sessionID: session.id, key: key))

        let local = try? await progressStore.progress(for: key)
        let server = await serverProgress
        guard current == generation else { return }
        var candidates: [ProgressCandidate] = []
        if let local {
            candidates.append(
                ProgressCandidate(
                    currentTime: local.currentTime, updatedAt: local.lastUpdate, isFinished: local.isFinished))
        }
        if let record = lastPlayedStore.load(), record.key == key {
            candidates.append(ProgressCandidate(currentTime: record.position, updatedAt: record.timestamp))
        }
        candidates.append(
            ProgressCandidate(
                currentTime: session.currentTime, updatedAt: server?.lastUpdate.map(Self.date(ms:)),
                isFinished: server?.isFinished ?? false))
        let extra = playWhenLoaded ? Self.nonNegative(willResume?() ?? 0) : 0
        let resumeTime = ResumePosition.startTime(
            explicit: explicitStart, candidates: candidates, duration: source.timeline.duration, now: now(),
            autoRewind: !settings.disableAutoRewind)
        let target = explicitStart == nil ? max(resumeTime - extra, 0) : resumeTime

        engine.setRate(Float(settings.playbackRate))
        rate = settings.playbackRate
        do {
            try await engine.load(source, at: target)
        } catch .superseded {
            return
        } catch {
            guard current == generation else { return }
            unloadedPosition = target
            tearDown(reason: .loadFailed)
            return fail(PlaybackCoordinatorError(engineError: error), generation: current)
        }
        guard current == generation else { return }
        phase = .loaded
        emit(.loaded(time: engine.currentTime))
        emit(.didSeek(time: engine.currentTime))
        saveLastPlayed()
        if playWhenLoaded { startEngine() }
    }

    /// Plays the current item: resumes a loaded one (rewinding by `seconds`, or by ``AutoRewind``
    /// for the time since it last played), or starts a session for a restored or failed one.
    public func resume(rewindingBy seconds: Double? = nil) async {
        guard let key = mediaKey else { return }
        switch phase {
        case .idle: return
        case .starting: playWhenLoaded = true
        case .unloaded: await play(itemID: key.libraryItemId, episodeID: key.episodeId, startTime: pendingStartTime)
        case .loaded: await resumeLoaded(rewindingBy: seconds)
        }
    }

    /// The single resume path for loaded media: ``willResume`` first, then one awaited seek back
    /// (which emits ``PlaybackCoordinatorEvent/didSeek(time:)`` with where it landed), then play.
    private func resumeLoaded(rewindingBy seconds: Double?) async {
        guard !engine.isPlaybackRequested else { return }
        let current = generation
        let extra = Self.nonNegative(willResume?() ?? 0)
        let time = engine.currentTime
        let rewound =
            if let seconds {
                time - Self.nonNegative(seconds)
            } else {
                AutoRewind.resumeTime(
                    currentTime: time, lastPlayed: lastPlayedAt, now: now(), isEnabled: !settings.disableAutoRewind)
            }
        let target = max(rewound - extra, 0)
        if target < time {
            _ = await seek(to: target)
            guard current == generation, phase == .loaded, !engine.isPlaybackRequested else { return }
        }
        startEngine()
    }

    public func pause() {
        switch phase {
        case .starting: playWhenLoaded = false
        case .loaded:
            guard engine.isPlaybackRequested else { return }
            engine.pause()
            lastPlayedAt = now()
            saveLastPlayed()
            emit(.paused(time: engine.currentTime))
        case .idle, .unloaded: return
        }
    }

    /// Seeks to a global time and returns where playback landed, or `nil` when a later seek
    /// replaced it or it failed. While unloaded, moves the position the next play starts from.
    @discardableResult
    public func seek(to time: Double) async -> Double? {
        switch phase {
        case .loaded:
            let target = engine.timeline?.clamp(time) ?? max(time, 0)
            guard await engine.seek(to: target) == .completed, phase == .loaded else { return nil }
            let landed = engine.currentTime
            emit(.didSeek(time: landed))
            saveLastPlayed()
            return landed
        case .unloaded:
            let finite = time.isFinite ? max(time, 0) : 0
            unloadedPosition = unloadedDuration > 0 ? min(finite, unloadedDuration) : finite
            pendingStartTime = unloadedPosition
            saveLastPlayed()
            return unloadedPosition
        case .idle, .starting:
            return nil
        }
    }

    /// Sets and saves the playback rate. Rates the settings reject are ignored.
    public func setRate(_ rate: Double) {
        settings.playbackRate = rate
        self.rate = settings.playbackRate
        engine.setRate(Float(self.rate))
    }

    /// Stops playback, closes the session and forgets the item, so it isn't restored at launch.
    public func stop() {
        generation += 1
        let hadItem = mediaKey != nil
        tearDown(reason: .stopped)
        mediaKey = nil
        error = nil
        pendingStartTime = nil
        unloadedPosition = 0
        unloadedDuration = 0
        phase = .idle
        lastPlayedStore.clear()
        if hadItem { emit(.itemChanged(nil)) }
    }

    /// Publishes the last-played item for this connection, paused at its saved position, without
    /// starting a session or loading the engine. Returns whether an item was restored.
    @discardableResult
    public func restoreLastPlayed() -> Bool {
        guard phase == .idle, let record = lastPlayedStore.load(),
            record.serverConnectionID == sessions.serverConnectionID
        else { return false }
        generation += 1
        mediaKey = record.key
        unloadedPosition = record.position.isFinite ? max(record.position, 0) : 0
        unloadedDuration = record.duration ?? 0
        lastPlayedAt = record.timestamp
        phase = .unloaded
        emit(.itemChanged(record.key))
        return true
    }

    /// Saves the current position as the last-played record. Call when the app moves to the
    /// background; pauses, seeks and loads save it already.
    public func saveLastPlayed() {
        guard let key = mediaKey, phase == .loaded || phase == .unloaded else { return }
        let date = now()
        lastPlayedSavedAt = date
        lastPlayedStore.save(
            LastPlayedRecord(
                serverConnectionID: key.serverConnectionID, libraryItemID: key.libraryItemId,
                episodeID: key.episodeId, position: currentTime, duration: duration > 0 ? duration : nil,
                timestamp: date))
    }

    // MARK: Engine events

    private func handle(_ event: AudioEngineEvent) {
        guard phase == .loaded else { return }
        switch event {
        case .tick(let time):
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
        engine.play()
        emit(.playbackStarted)
    }

    private func fail(_ error: PlaybackCoordinatorError, generation failed: Int) {
        guard failed == generation else { return }
        self.error = error
        if phase == .starting { phase = .unloaded }
        emit(.failed(error))
    }

    /// Closes the current session (if any) and unloads the engine.
    private func tearDown(reason: SessionCloseReason) {
        if phase == .loaded {
            unloadedPosition = engine.currentTime
            unloadedDuration = engine.duration
        }
        if let session, let key = mediaKey {
            self.session = nil
            let closing = ClosingSession(
                sessionID: session.id, key: key, currentTime: unloadedPosition, duration: unloadedDuration,
                reason: reason)
            emit(.sessionWillClose(closing))
            closeInBackground(sessionID: session.id, report: finalCloseReport?(closing))
        }
        if phase == .loaded || phase == .starting { engine.stop() }
        if phase != .idle { phase = .unloaded }
    }

    private func closeInBackground(sessionID: String, report: PlaybackSyncReport?) {
        guard closingSessionIDs.insert(sessionID).inserted else { return }
        let id = UUID()
        let sessions = self.sessions
        closeTasks[id] = Task { [weak self] in
            do {
                try await sessions.closeSession(id: sessionID, report: report)
            } catch {
                logger.info("Closing a playback session failed: \(String(describing: error), privacy: .public)")
            }
            self?.closeTasks[id] = nil
        }
    }

    /// Waits for the background closes started so far (tests).
    func waitForPendingCloses() async {
        for task in closeTasks.values { await task.value }
    }

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

    private static func nonNegative(_ value: Double) -> Double {
        value.isFinite ? max(value, 0) : 0
    }

    private static func date(ms: Int) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }
}
