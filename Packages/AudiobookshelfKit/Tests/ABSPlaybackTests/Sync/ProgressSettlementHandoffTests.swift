import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSData
@testable import ABSPlayback

/// A PATCH outcome the store couldn't save stays with the store, not the syncer that saw it, so a
/// replacement syncer sharing the store finishes it (#337).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProgressSettlementHandoffTests {
    private func edit(_ s: SyncHarness, _ time: Double) async throws {
        try await s.store.recordEdit(
            ProgressEdit(audio: .init(currentTime: time, duration: 3600, progress: time / 3600)), for: s.h.key("a"),
            now: s.h.clock.now)
    }

    /// The row is deleted and recreated while its PATCH is in flight, and the recreated row's
    /// shield can't be saved with the outcome. After that syncer is detached, a replacement
    /// saves the kept outcome and sends the recreated row's edit.
    @Test(arguments: [nil, APIError.http(status: 500, message: nil)])
    func aReplacementSyncerFinishesAKeptOutcome(patchError: APIError?) async throws {
        let s = try SyncHarness()
        let started = Gate()
        let response = Gate()
        s.service.state.withLock {
            $0.patchErrors = [patchError]
            $0.patchStarted = started
            $0.patchGates = [response]
        }
        try await edit(s, 50)
        let drain = Task { await s.syncer.drainPendingProgress() }
        await started.wait()
        #expect(try await s.store.deleteProgress(for: s.h.key("a")))
        s.h.clock.advance(by: 1)
        try await edit(s, 60)
        await s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        response.open()
        await drain.value
        s.syncer.detach()

        let clock = s.h.clock
        let service = StubProgressSyncService(serverConnectionID: s.h.connectionID)
        let replacement = ProgressSyncer(
            source: s.coordinator, service: service, store: s.store,
            clock: ProgressSyncClock(now: { clock.now }, uptime: { clock.now.timeIntervalSince1970 }),
            tickInterval: 0.5)
        await replacement.drainPendingProgress()

        #expect(service.patches.map(\.update) == [SyncHarness.audio(60)])
        #expect(s.service.patches.map(\.update) == [SyncHarness.audio(50)])
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == false)
        replacement.detach()
    }
}
