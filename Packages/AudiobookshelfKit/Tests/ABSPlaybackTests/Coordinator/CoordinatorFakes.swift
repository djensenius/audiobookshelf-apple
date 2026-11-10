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
    var pendingSeekTarget: Double?
    var timeline: PlaybackTimeline?
    var onEvent: (@MainActor (AudioEngineEvent) -> Void)?

    private(set) var loads: [(source: AudioEngineSource, time: Double)] = []
    private(set) var seeks: [Double] = []
    private(set) var stopCount = 0
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
    private var generation = 0

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
        state = isPlaybackRequested ? .playing : .paused
    }

    func play() {
        if failingPlays > 0 {
            failingPlays -= 1
            isPlaybackRequested = false
            state = .paused
            onEvent?(.failed(.audioSessionActivationFailed(description: "Session activation failed")))
            return
        }
        isPlaybackRequested = true
        state = pendingSeekTarget == nil ? .playing : .buffering
    }

    func pause() {
        isPlaybackRequested = false
        state = .paused
    }

    func stop() {
        generation += 1
        stopCount += 1
        isPlaybackRequested = false
        timeline = nil
        currentTime = 0
        pendingSeekTarget = nil
        state = .idle
    }

    func seek(to time: Double) async -> SeekResult {
        seeks.append(time)
        pendingSeekTarget = time
        if !seekGates.isEmpty { await seekGates.removeFirst().wait() }
        let result = seekResults.isEmpty ? SeekResult.completed : seekResults.removeFirst()
        if result == .completed {
            pendingSeekTarget = nil
            currentTime = time
            if state == .ended || state == .buffering { state = isPlaybackRequested ? .playing : .paused }
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
        state = isPlaybackRequested ? .playing : .paused
        onEvent?(.tick(target))
    }

    /// Plays to the end, as the real engine does: play is no longer requested.
    func finish() {
        isPlaybackRequested = false
        currentTime = duration
        state = .ended
        onEvent?(.endOfMedia)
    }

    func setRate(_ rate: Float) { defaultRate = rate }
    func setVolume(_ volume: Float) { self.volume = volume }
}

/// Sessions per item (ids `<item>-<n>`, unique per start), with optional gates on starts and
/// closes and a log of both in order. It models the server's one open session per device: a
/// start that reaches it takes over every other open session, and a close removes its own.
final class StubSessionService: PlaybackSessionService {
    struct State {
        var progress: [String: MediaProgress] = [:]
        var progressError: APIError?
        var serverTime: [String: Double] = [:]
        var sessionUpdatedAt: Date?
        var startGates: [String: Gate] = [:]
        var closeGates: [String: Gate] = [:]
        var startError: APIError?
        var resolveError: (any Error)?
        var closeError: APIError?
        var starts: [String] = []
        var closes: [String] = []
        var log: [String] = []
        var count = 0
        var openSessions: [String] = []
        var takenOver: [String] = []
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

    func startSession(itemID: String, episodeID: String?) async throws -> PlaybackSession {
        let (gate, error, time, id, updatedAt) = state.withLock { state in
            state.starts.append(itemID)
            state.log.append("start \(itemID)")
            state.count += 1
            return (
                state.startGates.removeValue(forKey: itemID), state.startError, state.serverTime[itemID] ?? 0,
                "\(itemID)-\(state.count)", state.sessionUpdatedAt
            )
        }
        // The gate holds the request before it reaches the server.
        await gate?.wait()
        if let error { throw error }
        state.withLock { state in
            state.takenOver += state.openSessions
            state.openSessions = [id]
        }
        return PlaybackSession(
            id: id, libraryItemId: itemID, episodeId: episodeID, mediaType: .book,
            chapters: [Chapter(id: 0, start: 0, end: 1000, title: "One"), Chapter(id: 1, start: 1000, end: 3600)],
            displayTitle: "Title \(itemID)", displayAuthor: "Author", coverPath: "/covers/\(itemID).jpg",
            duration: 3600, currentTime: time,
            updatedAt: updatedAt.map { Int($0.timeIntervalSince1970 * 1000) },
            audioTracks: [
                AudioTrack(index: 1, startOffset: 0, duration: 1800, mimeType: "audio/mpeg"),
                AudioTrack(index: 2, startOffset: 1800, duration: 1800, mimeType: "audio/mpeg"),
            ])
    }

    func mediaProgress(itemID: String, episodeID: String?) async throws -> MediaProgress? {
        try state.withLock { state in
            if let error = state.progressError { throw error }
            return state.progress[itemID]
        }
    }

    func resolveStream(for session: PlaybackSession) async throws -> ResolvedStream {
        if let error = state.withLock({ $0.resolveError }) { throw error }
        let tracks = session.audioTracks.map { track in
            PlayableTrack(
                url: URL(filePath: "/\(session.id)/\(track.index ?? 0)"), mimeType: track.mimeType,
                startOffset: track.startOffset ?? 0, duration: track.duration, authentication: .session)
        }
        return ResolvedStream(
            plan: StreamPlan(kind: .directPlay, transport: .urlAsset, tracks: tracks), urls: tracks.map(\.url))
    }

    func closeSession(id: String, report: PlaybackSyncReport?) async throws {
        let (gate, error) = state.withLock { state in
            state.closes.append(id)
            state.log.append("close \(id)")
            return (state.closeGates.removeValue(forKey: id), state.closeError)
        }
        await gate?.wait()
        state.withLock { state in
            state.openSessions.removeAll { $0 == id }
            state.log.append("close \(id) done")
        }
        if let error { throw error }
    }
}

@MainActor
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

    func streamingDecision() async -> NetworkDecision {
        checks += 1
        if let gate {
            self.gate = nil
            let decision = decision
            await gate.wait()
            return decision
        }
        return decision
    }
}

@MainActor
final class InMemoryLastPlayedStore: LastPlayedStoring {
    var record: LastPlayedRecord?

    func load() -> LastPlayedRecord? { record }
    func save(_ record: LastPlayedRecord) { self.record = record }
    func clear() { record = nil }
}

/// A sleep for the close-wait timeout: never elapses in tests (it is cancelled when the closes
/// finish) unless `elapsesImmediately` is set.
final class TestSleep: Sendable {
    private let immediate = Mutex(false)

    var elapsesImmediately: Bool {
        get { immediate.withLock { $0 } }
        set { immediate.withLock { $0 = newValue } }
    }

    func sleep(_ duration: Duration) async {
        if elapsesImmediately { return }
        try? await Task.sleep(for: .seconds(3600))
    }
}
