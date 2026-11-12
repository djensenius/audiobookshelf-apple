import ABSCore
import ABSData
import Foundation
import Observation
import Synchronization

@testable import ABSAPI
@testable import ABSPlayback

/// Suspends callers until ``open()``.
final class Gate: Sendable {
    private let state = Mutex<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resume = state.withLock { state in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// A settable wall clock.
final class TestClock: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    var now: Date { date.withLock { $0 } }
    func advance(by seconds: TimeInterval) { date.withLock { $0 += seconds } }
    func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
}

/// An engine that loads instantly (or when a gate opens) and records what it was asked to do.
@MainActor
@Observable
final class CoordinatorTestEngine: AudioEngineProtocol {
    var state: PlaybackState = .idle
    var currentTime: Double = 0
    var duration: Double { timeline?.duration ?? 0 }
    var currentTrackIndex: Int?
    var defaultRate: Float = 1
    var volume: Float = 1
    var isPlaybackRequested = false
    var wasPlaybackRequestedAtFailure = false
    var pendingSeekTarget: Double?
    var isAudioSessionActive = false
    var timeline: PlaybackTimeline?
    var onEvent: (@MainActor (AudioEngineEvent) -> Void)?

    private(set) var loads: [(source: AudioEngineSource, time: Double)] = []
    private(set) var seeks: [Double] = []
    /// Includes interrupted and superseded seeks, so tests can drain gated calls.
    private(set) var returnedSeekCount = 0
    private(set) var stopCount = 0
    private(set) var unloadCount = 0
    private(set) var playCount = 0
    private(set) var volumes: [Float] = []
    private(set) var volumeAtPause: Float?
    /// Gates for the next loads and seeks, in order; without one they complete immediately.
    var loadGates: [Gate] = []
    var seekGates: [Gate] = []
    var loadError: AudioEngineError?
    /// How many of the next loads end like the real engine's after two interrupted initial seeks:
    /// they return normally, paused at 0, with the start still `pendingSeekTarget`.
    var interruptedLoads = 0
    /// The results of the next seeks, in order; without one a seek completes. Any other result
    /// leaves the position and `pendingSeekTarget`, as the real engine does.
    var seekResults: [SeekResult] = []
    /// How many of the next plays fail synchronously, as an audio session activation failure does.
    var failingPlays = 0
    /// How many plays are silently refused while a prior engine failure remains sticky.
    var silentlyRefusingPlays = 0
    /// Starts the player buffering rather than playing, as a stream waiting for its first data does
    /// (`waitingToPlayAtSpecifiedRate`).
    var startsBuffering = false
    private var generation = 0
    private var seekGeneration = 0

    func load(_ source: AudioEngineSource, at time: Double) async throws(AudioEngineError) {
        generation += 1
        let current = generation
        loads.append((source, time))
        state = .loading
        pendingSeekTarget = nil
        if !loadGates.isEmpty { await loadGates.removeFirst().wait() }
        guard current == generation else { throw .superseded }
        if let loadError {
            state = .failed(loadError)
            throw loadError
        }
        timeline = source.timeline
        if interruptedLoads > 0 {
            interruptedLoads -= 1
            currentTime = 0
            pendingSeekTarget = source.timeline.clamp(time)
            state = .paused
            return
        }
        currentTime = source.timeline.clamp(time)
        if isPlaybackRequested { startPlayer() } else { state = .paused }
    }

    /// As the real engine does: activates the audio session, then starts the player.
    private func startPlayer() {
        isAudioSessionActive = true
        state = startsBuffering ? .buffering : .playing
    }

    /// As the real engine does, defers playing (shown as buffering) while a seek is in flight.
    func play() {
        playCount += 1
        // As the real engine does, a sticky failure refuses play until a seek or load.
        if case .failed = state { return }
        if silentlyRefusingPlays > 0 {
            silentlyRefusingPlays -= 1
            isPlaybackRequested = false
            state = .paused
            return
        }
        if failingPlays > 0 {
            failingPlays -= 1
            isPlaybackRequested = false
            state = .paused
            isAudioSessionActive = false
            onEvent?(.failed(.audioSessionActivationFailed(description: "Session activation failed")))
            return
        }
        isPlaybackRequested = true
        if pendingSeekTarget == nil { startPlayer() } else { state = .buffering }
    }

    func pause() {
        volumeAtPause = volume
        isPlaybackRequested = false
        state = .paused
    }

    func pauseForOutputLoss() {
        pause()
        onEvent?(.outputLost)
    }

    func stop() {
        generation += 1
        stopCount += 1
        isPlaybackRequested = false
        isAudioSessionActive = false
        timeline = nil
        currentTime = 0
        pendingSeekTarget = nil
        state = .idle
    }

    /// As ``stop()``, but counted apart: the real engine keeps the audio session active.
    func unload() {
        generation += 1
        unloadCount += 1
        isPlaybackRequested = false
        isAudioSessionActive = false
        timeline = nil
        currentTime = 0
        pendingSeekTarget = nil
        state = .idle
    }

    func seek(to time: Double) async -> SeekResult {
        defer { returnedSeekCount += 1 }
        seekGeneration += 1
        let request = seekGeneration
        let current = generation
        seeks.append(time)
        pendingSeekTarget = time
        // As the real engine does, a seek clears a failure (rebuilding the item).
        if case .failed = state { state = .paused }
        let result = seekResults.isEmpty ? SeekResult.completed : seekResults.removeFirst()
        if !seekGates.isEmpty { await seekGates.removeFirst().wait() }
        // A late seek never overwrites a newer seek, load or stop (including the same target).
        guard current == generation, request == seekGeneration else { return .superseded }
        if result == .completed {
            pendingSeekTarget = nil
            currentTime = time
            if state == .ended || state == .buffering {
                if isPlaybackRequested { startPlayer() } else { state = .paused }
            }
        } else {
            state = isPlaybackRequested ? .buffering : .paused
        }
        return result
    }

    /// Lands the pending seek, as the real engine's retry does once the player can: the position
    /// becomes the target, the player starts if play was requested, and the next tick fires.
    func landPendingSeek() {
        guard let target = pendingSeekTarget else { return }
        pendingSeekTarget = nil
        currentTime = target
        if isPlaybackRequested { startPlayer() } else { state = .paused }
        onEvent?(.tick(target))
    }

    /// Fails as the real engine does: play is no longer requested and the state is sticky until a
    /// seek or load.
    func fail(_ error: AudioEngineError) {
        wasPlaybackRequestedAtFailure = isPlaybackRequested
        isPlaybackRequested = false
        state = .failed(error)
        onEvent?(.failed(error))
    }

    /// Plays to the end, as the real engine does: play is no longer requested.
    func finish() {
        isPlaybackRequested = false
        currentTime = duration
        state = .ended
        onEvent?(.endOfMedia)
    }

    func setRate(_ rate: Float) { defaultRate = rate }
    func setVolume(_ volume: Float) {
        self.volume = volume
        volumes.append(volume)
    }
}

/// Sessions per item (ids `<item>-<n>`, unique per start), with optional gates on starts and
/// closes and a log of both in order. It models the server's one open session per device: a
/// start that reaches it takes over every other open session, and a close removes its own.
final class StubSessionService: PlaybackSessionService {
    struct State {
        /// Opt-in shared server; legacy gates/overrides remain for unconfigured tests only.
        var sessionClient: SessionModelClient?
        var progress: [String: MediaProgress] = [:]
        var progressReads: [MediaKey] = []
        var progressError: APIError?
        var serverTime: [String: Double] = [:]
        var sessionUpdatedAt: Date?
        var startGates: [String: Gate] = [:]
        /// Metadata and expanded library item for an item's sessions (none by default).
        var metadata: [String: (MediaMetadata, LibraryItem?)] = [:]
        /// Native-engine fixtures; tests without overrides retain the default session and stream.
        var sessionOverride: PlaybackSession?
        var streamOverride: ResolvedStream?
        var closeGates: [String: Gate] = [:]
        var startError: APIError?
        var resolveError: (any Error)?
        var resolveGate: Gate?
        var resolutions = 0
        var canceledResolutions = 0
        var closeError: APIError?
        var refreshes = 0
        /// The `rejected` token of each refresh.
        var refreshedTokens: [String?] = []
        var refreshError: APIError?
        var starts: [String] = []
        var closes: [String] = []
        var canceledCloses: [String] = []
        var closeReports: [String: PlaybackSyncReport] = [:]
        var log: [String] = []
        var count = 0
        var openSessions: [String] = []
        var takenOver: [String] = []
        /// What `GET /api/session/{id}` answers, and the ids looked up.
        var sessionStatus = PlaybackSessionStatus.unknown
        var sessionLookups: [String] = []
    }

    let serverConnectionID: UUID
    let state = Mutex(State())

    init(serverConnectionID: UUID) {
        self.serverConnectionID = serverConnectionID
    }

    var starts: [String] { state.withLock { $0.starts } }
    var closes: [String] { state.withLock { $0.closes } }
    var log: [String] { state.withLock { $0.log } }
    /// The sessions open on the server now.
    var openSessions: [String] { state.withLock { $0.openSessions } }
    /// The sessions the server closed because another start took over.
    var takenOver: [String] { state.withLock { $0.takenOver } }

    func sessionStatus(id: String) async -> PlaybackSessionStatus {
        state.withLock {
            $0.sessionLookups.append(id)
            return $0.sessionStatus
        }
    }

    func startSession(itemID: String, episodeID: String?) async throws -> PlaybackSession {
        // As the API client's request does, a start for a cancelled caller sends nothing and throws.
        try Task.checkCancellation()
        if let client = state.withLock({ $0.sessionClient }) {
            state.withLock {
                $0.starts.append(itemID)
                $0.log.append("start \(itemID)")
            }
            return try await client.model.start(client, itemID: itemID, episodeID: episodeID)
        }
        let (gate, error, time, id, updatedAt, metadata) = state.withLock { state in
            state.starts.append(itemID)
            state.log.append("start \(itemID)")
            state.count += 1
            return (
                state.startGates.removeValue(forKey: itemID), state.startError, state.serverTime[itemID] ?? 0,
                "\(itemID)-\(state.count)", state.sessionUpdatedAt, state.metadata[itemID]
            )
        }
        // The gate holds the request before it reaches the server.
        await gate?.wait()
        if let error {
            state.withLock { $0.log.append("start \(itemID) failed") }
            throw error
        }
        state.withLock { state in
            state.takenOver += state.openSessions
            state.openSessions = [id]
        }
        if let session = state.withLock({ $0.sessionOverride }) { return session }
        return PlaybackSession(
            id: id, libraryItemId: itemID, episodeId: episodeID, mediaType: .book,
            mediaMetadata: metadata?.0,
            chapters: [Chapter(id: 0, start: 0, end: 1000, title: "One"), Chapter(id: 1, start: 1000, end: 3600)],
            displayTitle: "Title \(itemID)", displayAuthor: "Author", coverPath: "/covers/\(itemID).jpg",
            duration: 3600, currentTime: time,
            updatedAt: updatedAt.map { Int($0.timeIntervalSince1970 * 1000) },
            audioTracks: [
                AudioTrack(index: 1, startOffset: 0, duration: 1800, mimeType: "audio/mpeg"),
                AudioTrack(index: 2, startOffset: 1800, duration: 1800, mimeType: "audio/mpeg"),
            ], libraryItem: metadata?.1)
    }

    func mediaProgress(itemID: String, episodeID: String?) async throws -> MediaProgress? {
        state.withLock {
            $0.progressReads.append(
                MediaKey(serverConnectionID: serverConnectionID, libraryItemId: itemID, episodeId: episodeID))
        }
        if let client = state.withLock({ $0.sessionClient }) {
            return try await client.model.fetchProgress(client, itemID: itemID, episodeID: episodeID)
        }
        return try state.withLock { state in
            if let error = state.progressError { throw error }
            return state.progress[itemID]
        }
    }

    func resolveStream(for session: PlaybackSession) async throws -> ResolvedStream {
        let gate = state.withLock {
            $0.resolutions += 1
            return $0.resolveGate
        }
        await gate?.wait()
        if Task.isCancelled { state.withLock { $0.canceledResolutions += 1 } }
        if let error = state.withLock({ $0.resolveError }) { throw error }
        if let stream = state.withLock({ $0.streamOverride }) { return stream }
        let tracks = session.audioTracks.map { track in
            PlayableTrack(
                url: URL(filePath: "/\(session.id)/\(track.index ?? 0)"), mimeType: track.mimeType,
                startOffset: track.startOffset ?? 0, duration: track.duration, authentication: .session)
        }
        return ResolvedStream(
            plan: StreamPlan(kind: .directPlay, transport: .urlAsset, tracks: tracks), urls: tracks.map(\.url),
            accessToken: "token-\(session.id)")
    }

    func closeSession(id: String, report: PlaybackSyncReport?) async throws {
        let (gate, error) = state.withLock { state in
            state.closes.append(id)
            state.closeReports[id] = report
            state.log.append("close \(id)")
            return (state.closeGates.removeValue(forKey: id), state.closeError)
        }
        await gate?.wait()
        if Task.isCancelled { state.withLock { $0.canceledCloses.append(id) } }
        if let client = state.withLock({ $0.sessionClient }) {
            try await client.model.close(client, id: id, report: report)
            state.withLock { $0.log.append("close \(id) done") }
            return
        }
        state.withLock { state in
            state.openSessions.removeAll { $0 == id }
            state.log.append("close \(id) done")
        }
        if let error { throw error }
    }

    func refreshStreamAccess(replacing rejected: String?) async throws {
        let error = state.withLock {
            $0.refreshes += 1
            $0.refreshedTokens.append(rejected)
            $0.log.append("refresh")
            return $0.refreshError
        }
        if let error { throw error }
    }

    /// Model-only lookup seams; unlike the legacy recording arrays these share server state.
    func openSession(id: String) async throws -> PlaybackSession {
        guard let client = state.withLock({ $0.sessionClient }) else { preconditionFailure("Configure sessionClient") }
        return try await client.model.lookup(client, id: id)
    }

    func listeningSessions(
        itemID: String, episodeID: String? = nil, page: Int = 0, itemsPerPage: Int = 10
    ) async throws -> ListeningSessionsPage {
        guard let client = state.withLock({ $0.sessionClient }) else { preconditionFailure("Configure sessionClient") }
        return try await client.model.records(
            client, itemID: itemID, episodeID: episodeID, page: page, itemsPerPage: itemsPerPage)
    }
}

/// Observable like ``AppSettings``, so rate changes reach observers (Now Playing).
@MainActor
@Observable
final class StubPlaybackSettings: PlaybackSettingsProviding {
    var playbackRate = 1.0 {
        didSet { if !(playbackRate.isFinite && playbackRate > 0) { playbackRate = oldValue } }
    }
    var disableAutoRewind = false
    var enableMp3IndexSeeking = false
    var streamingUsingCellular = CellularPolicy.always
}

@MainActor
final class StubStreamingPolicy: StreamingPolicyChecking {
    var decision = NetworkDecision.allowed
    /// Holds the next check until opened; the decision is read when it returns.
    var gate: Gate?
    private(set) var checks = 0
    /// Checks that returned, including gated ones.
    private(set) var returns = 0
    /// What ``currentStreamingDecision()`` says; `decision` when `nil`.
    var currentDecision: NetworkDecision?

    func streamingDecision() async -> NetworkDecision {
        checks += 1
        defer { returns += 1 }
        if let gate {
            self.gate = nil
            let decision = decision
            await gate.wait()
            return decision
        }
        return decision
    }

    func currentStreamingDecision() -> NetworkDecision { currentDecision ?? decision }
}

@MainActor
final class InMemoryLastPlayedStore: LastPlayedStoring {
    var record: LastPlayedRecord?

    func load() -> LastPlayedRecord? { record }
    func save(_ record: LastPlayedRecord) { self.record = record }
    func clear() { record = nil }
}

/// A sleep for the close-wait timeout: never elapses in tests (it is cancelled when the closes
/// finish) unless `elapsesImmediately` is set, or `isManual` is and a test fires it.
final class TestSleep: Sendable {
    private let immediate = Mutex(false)
    private let manual = Mutex(false)
    private let calls = Mutex<[Duration]>([])
    private let waiting = Mutex<[(id: UUID, continuation: CheckedContinuation<Void, Never>)]>([])

    var durations: [Duration] { calls.withLock { $0 } }

    var elapsesImmediately: Bool {
        get { immediate.withLock { $0 } }
        set { immediate.withLock { $0 = newValue } }
    }

    /// Each sleep then waits until ``fireOldest()`` or cancellation ends it.
    var isManual: Bool {
        get { manual.withLock { $0 } }
        set { manual.withLock { $0 = newValue } }
    }

    /// The manual sleeps waiting now.
    var waitingCount: Int { waiting.withLock { $0.count } }

    func sleep(_ duration: Duration) async {
        calls.withLock { $0.append(duration) }
        if elapsesImmediately { return }
        guard isManual else {
            try? await Task.sleep(for: .seconds(3600))
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Checked under the lock, so a cancel can't fall between the check and registering.
                let cancelled = waiting.withLock { waiting in
                    if Task.isCancelled { return true }
                    waiting.append((id, continuation))
                    return false
                }
                if cancelled { continuation.resume() }
            }
        } onCancel: {
            waiting.withLock { waiting in
                waiting.firstIndex { $0.id == id }.map { waiting.remove(at: $0).continuation }
            }?.resume()
        }
    }

    /// Ends the sleep that started first among those waiting.
    func fireOldest() {
        waiting.withLock { $0.isEmpty ? nil : $0.removeFirst().continuation }?.resume()
    }
}
