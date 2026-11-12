import ABSCore
import ABSData
import Foundation
import Synchronization

@testable import ABSAPI
@testable import ABSPlayback

/// Records `/sync` reports and progress PATCHes; each call takes the next queued error (`nil`
/// succeeds) and the next gate, if any.
final class StubProgressSyncService: ProgressSyncService {
    /// An explicitly dated server write, independently gated from response delivery.
    /// Only configured reports mutate canonical progress; other tests retain the recording stub.
    struct ServerSync: Sendable {
        let key: MediaKey
        let processedAt: Date
        let beforeProcessing: Gate
        let processed: Gate
        let response: Gate
    }

    struct Patch: Equatable {
        var itemID: String
        var episodeID: String?
        var update: MediaProgressUpdate
    }

    struct State {
        /// Opt-in to the same session state used by StubSessionService.
        var sessionClient: SessionModelClient?
        var syncs: [(id: String, report: PlaybackSyncReport)] = []
        var patches: [Patch] = []
        /// With a session client, a non-nil error fails the request before it reaches the model.
        var syncErrors: [APIError?] = []
        var patchErrors: [APIError?] = []
        var syncGates: [Gate] = []
        /// Model `/sync` requests the client gives up on (`.timedOut`) once they have entered the
        /// server; the model still completes each when the test opens its gates.
        var abandonedSyncs: [ReconciliationSessionModel.Request] = []
        /// Without a session client, `GET /api/session/:id` answers these in order, then 404.
        var lookupReplies: [Result<PlaybackSession, APIError>] = []
        var serverSyncs: [ServerSync] = []
        var serverProgress: [MediaKey: MediaProgress] = [:]
        var fetches: [MediaKey] = []
        var fetchGates: [Gate] = []
        var fetchErrors: [APIError?] = []
        /// Explicit sequential canonical replies, including post-PATCH values. Without a session
        /// client PATCH is recording-only; an empty queue falls back to serverProgress.
        var fetchReplies: [MediaProgress?] = []
        var fetchStarted: Gate?
        var patchGates: [Gate] = []
        var patchStarted: Gate?
        var log: [String] = []
        var canceledCalls: [String] = []
        var syncWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    let serverConnectionID: UUID
    let state = Mutex(State())

    init(serverConnectionID: UUID) {
        self.serverConnectionID = serverConnectionID
    }

    var reports: [PlaybackSyncReport] { state.withLock { $0.syncs.map(\.report) } }
    var patches: [Patch] { state.withLock { $0.patches } }
    var log: [String] { state.withLock { $0.log } }

    /// Snapshot at request time, then hold response delivery independently of local writes.
    /// The existing recording fixture starts with no canonical rows; explicit ServerSync
    /// fixtures populate this same map. No production fallback or synthetic dated zero is used.
    func fetchProgress(itemID: String, episodeID: String?) async throws -> MediaProgress? {
        let key = MediaKey(
            serverConnectionID: serverConnectionID, libraryItemId: itemID, episodeId: episodeID)
        if let client = state.withLock({ $0.sessionClient }) {
            let error = state.withLock { state in
                state.fetches.append(key)
                state.log.append("get \(itemID)")
                return state.fetchErrors.isEmpty ? nil : state.fetchErrors.removeFirst()
            }
            // A queued error never reaches the model, like a failed connection.
            if let error { throw error }
            return try await client.model.fetchProgress(client, itemID: itemID, episodeID: episodeID)
        }
        let (progress, gate, error, started) = state.withLock { state in
            state.fetches.append(key)
            state.log.append("get \(itemID)")
            return (
                state.fetchReplies.isEmpty ? state.serverProgress[key] : state.fetchReplies.removeFirst(),
                state.fetchGates.isEmpty ? nil : state.fetchGates.removeFirst(),
                state.fetchErrors.isEmpty ? nil : state.fetchErrors.removeFirst(), state.fetchStarted
            )
        }
        started?.open()
        await gate?.wait()
        if Task.isCancelled { state.withLock { $0.canceledCalls.append("get") } }
        if let error { throw error }
        return progress
    }

    /// Canonical GET representation: an absent row is nil, never an undated zero.
    func mediaProgress(itemID: String, episodeID: String? = nil) async -> MediaProgress? {
        let key = MediaKey(
            serverConnectionID: serverConnectionID, libraryItemId: itemID, episodeId: episodeID)
        return state.withLock {
            $0.log.append("get \(itemID)")
            return $0.serverProgress[key]
        }
    }

    /// Returns once `count` reports have reached the service (before their gates).
    func waitForSyncs(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let reached = state.withLock { state in
                if state.syncs.count >= count { return true }
                state.syncWaiters.append((count, continuation))
                return false
            }
            if reached { continuation.resume() }
        }
    }

    func syncSession(id: String, report: PlaybackSyncReport) async throws {
        let (gate, error, number, reached, serverSync) = state.withLock { state in
            state.syncs.append((id, report))
            state.log.append("sync \(state.syncs.count)")
            let reached = state.syncWaiters.filter { $0.count <= state.syncs.count }.map(\.continuation)
            state.syncWaiters.removeAll { $0.count <= state.syncs.count }
            return (
                state.syncGates.isEmpty ? nil : state.syncGates.removeFirst(),
                state.syncErrors.isEmpty ? nil : state.syncErrors.removeFirst(), state.syncs.count, reached,
                state.serverSyncs.isEmpty ? nil : state.serverSyncs.removeFirst()
            )
        }
        for continuation in reached { continuation.resume() }
        await gate?.wait()
        if let client = state.withLock({ $0.sessionClient }) {
            // A queued error never reaches the model, like a failed connection.
            if let error { throw error }
            if let abandoned = state.withLock({ $0.abandonedSyncs.isEmpty ? nil : $0.abandonedSyncs.removeFirst() }) {
                // The server carries on with the request; the client stops waiting for it.
                Task { try? await client.model.sync(client, id: id, report: report) }
                await abandoned.entered.wait()
                state.withLock { $0.log.append("sync \(number) timed out") }
                throw APIError.timedOut
            }
            try await client.model.sync(client, id: id, report: report)
            state.withLock { $0.log.append("sync \(number) done") }
            return
        }
        if let serverSync, error == nil {
            await serverSync.beforeProcessing.wait()
            // Online /sync carries no client edit timestamp. The server dates the write when
            // it processes the captured report, which may be later than a newer local edit.
            let milliseconds = Int(serverSync.processedAt.timeIntervalSince1970 * 1000)
            state.withLock {
                $0.serverProgress[serverSync.key] = MediaProgress(
                    id: "p-\(serverSync.key.libraryItemId)", libraryItemId: serverSync.key.libraryItemId,
                    episodeId: serverSync.key.episodeId, duration: report.duration,
                    progress: report.currentTime / report.duration, currentTime: report.currentTime,
                    ebookProgress: 0, lastUpdate: milliseconds)
                $0.log.append(
                    "sync \(number) processed \(serverSync.key.libraryItemId) position=\(report.currentTime) lastUpdate=\(milliseconds)"
                )
            }
            serverSync.processed.open()
            await serverSync.response.wait()
        }
        if Task.isCancelled { state.withLock { $0.canceledCalls.append("sync") } }
        state.withLock { $0.log.append("sync \(number) done") }
        if let error { throw error }
    }

    func openSession(id: String) async throws -> PlaybackSession {
        let (client, reply) = state.withLock { state in
            state.log.append("lookup \(id)")
            return (state.sessionClient, state.lookupReplies.isEmpty ? nil : state.lookupReplies.removeFirst())
        }
        if let client { return try await client.model.lookup(client, id: id) }
        return try (reply ?? .failure(.notFound)).get()
    }

    func updateProgress(itemID: String, episodeID: String?, _ update: MediaProgressUpdate) async throws {
        let (gate, error, started) = state.withLock { state in
            state.patches.append(Patch(itemID: itemID, episodeID: episodeID, update: update))
            state.log.append("patch \(itemID)")
            return (
                state.patchGates.isEmpty ? nil : state.patchGates.removeFirst(),
                state.patchErrors.isEmpty ? nil : state.patchErrors.removeFirst(), state.patchStarted
            )
        }
        started?.open()
        await gate?.wait()
        if Task.isCancelled { state.withLock { $0.canceledCalls.append("patch") } }
        if let error { throw error }
        // A queued error above never reaches the shared model, like a failed connection.
        if let client = state.withLock({ $0.sessionClient }) {
            try await client.model.update(client, itemID: itemID, episodeID: episodeID, update)
        }
    }
}

/// A coordinator with fakes (``CoordinatorHarness``) and a ``ProgressSyncer`` following it, on
/// the harness clock: the monotonic clock is the wall clock's seconds.
@MainActor
struct SyncHarness {
    let h: CoordinatorHarness
    let service: StubProgressSyncService
    let syncer: ProgressSyncer
    /// The syncer's retry wakes; they sleep until a test fires them.
    let sleeper = ManualSleeper()

    init(
        progressStore: LocalProgressStore? = nil, connectionID: UUID = UUID(),
        paths: (any NetworkPathSource)? = nil
    ) throws {
        h = try CoordinatorHarness(progressStore: progressStore, connectionID: connectionID)
        h.settings.disableAutoRewind = true
        service = StubProgressSyncService(serverConnectionID: connectionID)
        let clock = h.clock
        syncer = ProgressSyncer(
            source: h.coordinator, service: service, store: h.progressStore,
            clock: ProgressSyncClock(
                now: { clock.now }, uptime: { clock.now.timeIntervalSince1970 }, sleep: sleeper.sleep),
            tickInterval: 0.5, paths: paths)
    }

    var coordinator: PlaybackCoordinator { h.coordinator }
    var store: LocalProgressStore { h.progressStore }

    /// Plays `seconds` of wall-clock time in 0.5 s engine ticks, advancing media time by `rate`.
    /// Like real time, the work each tick queues finishes before the next tick, unless
    /// `settling` is off (a request is held at a gate).
    func play(for seconds: Double, rate: Double = 1, settling: Bool = true) async {
        if settling { await settle() }
        for _ in 0..<Int((seconds / 0.5).rounded()) {
            h.clock.advance(by: 0.5)
            h.engine.currentTime += 0.5 * rate
            h.engine.onEvent?(.tick(h.engine.currentTime))
            if settling { await settle() }
        }
    }

    func settle() async {
        await syncer.waitForIdle()
    }

    static func audio(_ time: Double) -> MediaProgressUpdate {
        .audio(currentTime: time, duration: 3600, progress: time / 3600)
    }
}

/// One path stream that tests feed by hand; the syncer opens it once. Like
/// `SystemNetworkPathSource`, it keeps only the newest path while its consumer is busy.
final class StubNetworkPathSource: NetworkPathSource, Sendable {
    private let stream: AsyncStream<NetworkPath>
    private let continuation: AsyncStream<NetworkPath>.Continuation
    private let terminated = Mutex(false)

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in self?.terminated.withLock { $0 = true } }
    }

    /// Whether the stream's consumer stopped (its task was cancelled).
    var isTerminated: Bool { terminated.withLock { $0 } }

    func paths() -> AsyncStream<NetworkPath> { stream }

    func send(_ path: NetworkPath) { continuation.yield(path) }
}

/// A sleep that ends only when a test fires it, recording each requested delay.
final class ManualSleeper: Sendable {
    private struct State {
        var delays: [TimeInterval] = []
        var waiting: [UUID: CheckedContinuation<Void, any Error>] = [:]
        var credits = 0
    }

    private let state = Mutex(State())

    /// Every delay requested so far, in order.
    var delays: [TimeInterval] { state.withLock { $0.delays } }
    /// The sleeps waiting now; a cancelled one leaves at once.
    var waitingCount: Int { state.withLock { $0.waiting.count } }

    @Sendable func sleep(_ delay: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Cancellation is read under the lock the cancel handler takes, so a cancel can't
                // fall between the check and registering (the handler would find no waiter).
                let resume: Bool?
                resume = state.withLock { state in
                    state.delays.append(delay)
                    if Task.isCancelled { return false }
                    guard state.credits == 0 else {
                        state.credits -= 1
                        return true
                    }
                    state.waiting[id] = continuation
                    return nil
                }
                switch resume {
                case true?: continuation.resume()
                case false?: continuation.resume(throwing: CancellationError())
                case nil: break
                }
            }
        } onCancel: {
            state.withLock { $0.waiting.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    /// Ends every sleep waiting now or, if none is, the next one to start.
    func fire() {
        let waiting = state.withLock { state in
            if state.waiting.isEmpty { state.credits += 1 }
            defer { state.waiting.removeAll() }
            return Array(state.waiting.values)
        }
        for continuation in waiting { continuation.resume() }
    }
}
