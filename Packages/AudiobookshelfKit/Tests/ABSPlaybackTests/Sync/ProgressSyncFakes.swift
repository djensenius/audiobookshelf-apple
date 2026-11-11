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
        var syncs: [(id: String, report: PlaybackSyncReport)] = []
        var patches: [Patch] = []
        var syncErrors: [APIError?] = []
        var patchErrors: [APIError?] = []
        var syncGates: [Gate] = []
        var serverSyncs: [ServerSync] = []
        var serverProgress: [MediaKey: MediaProgress] = [:]
        var fetches: [MediaKey] = []
        var fetchGates: [Gate] = []
        var fetchErrors: [APIError?] = []
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
        let (progress, gate, error, started) = state.withLock { state in
            state.fetches.append(key)
            state.log.append("get \(itemID)")
            return (
                state.serverProgress[key], state.fetchGates.isEmpty ? nil : state.fetchGates.removeFirst(),
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
    }
}

/// A coordinator with fakes (``CoordinatorHarness``) and a ``ProgressSyncer`` following it, on
/// the harness clock: the monotonic clock is the wall clock's seconds.
@MainActor
struct SyncHarness {
    let h: CoordinatorHarness
    let service: StubProgressSyncService
    let syncer: ProgressSyncer

    init(progressStore: LocalProgressStore? = nil, connectionID: UUID = UUID()) throws {
        h = try CoordinatorHarness(progressStore: progressStore, connectionID: connectionID)
        h.settings.disableAutoRewind = true
        service = StubProgressSyncService(serverConnectionID: connectionID)
        let clock = h.clock
        syncer = ProgressSyncer(
            source: h.coordinator, service: service, store: h.progressStore,
            clock: ProgressSyncClock(now: { clock.now }, uptime: { clock.now.timeIntervalSince1970 }),
            tickInterval: 0.5)
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
