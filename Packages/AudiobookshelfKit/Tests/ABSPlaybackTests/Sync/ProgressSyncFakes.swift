import ABSCore
import ABSData
import Foundation
import Synchronization

@testable import ABSAPI
@testable import ABSPlayback

/// Records `/sync` reports and progress PATCHes; each call takes the next queued error (`nil`
/// succeeds) and the next gate, if any.
final class StubProgressSyncService: ProgressSyncService {
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
        var log: [String] = []
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
        let (gate, error, number, reached) = state.withLock { state in
            state.syncs.append((id, report))
            state.log.append("sync \(state.syncs.count)")
            let reached = state.syncWaiters.filter { $0.count <= state.syncs.count }.map(\.continuation)
            state.syncWaiters.removeAll { $0.count <= state.syncs.count }
            return (
                state.syncGates.isEmpty ? nil : state.syncGates.removeFirst(),
                state.syncErrors.isEmpty ? nil : state.syncErrors.removeFirst(), state.syncs.count, reached
            )
        }
        for continuation in reached { continuation.resume() }
        await gate?.wait()
        state.withLock { $0.log.append("sync \(number) done") }
        if let error { throw error }
    }

    func updateProgress(itemID: String, episodeID: String?, _ update: MediaProgressUpdate) async throws {
        let error = state.withLock { state in
            state.patches.append(Patch(itemID: itemID, episodeID: episodeID, update: update))
            state.log.append("patch \(itemID)")
            return state.patchErrors.isEmpty ? nil : state.patchErrors.removeFirst()
        }
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
