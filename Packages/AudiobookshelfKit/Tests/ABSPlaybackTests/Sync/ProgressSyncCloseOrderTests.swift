import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// Records the handoffs the syncer gives the coordinator's final closes.
@MainActor
final class HandoffLog {
    var handoffs: [PlaybackCloseHandoff] = []

    init(_ s: SyncHarness) {
        let finalReport = s.coordinator.finalCloseReport
        s.coordinator.finalCloseReport = { [weak self] closing in
            let handoff = finalReport?(closing)
            if let handoff { self?.handoffs.append(handoff) }
            return handoff
        }
    }

    /// Waits until the first close is held by the report in flight, and returns that report's barrier.
    func heldClose(sourceLocation: SourceLocation = #_sourceLocation) async throws -> PlaybackCloseResult<Void> {
        await yieldUntil({ !handoffs.isEmpty }, sourceLocation: sourceLocation)
        let barrier = try #require(handoffs.first?.sessionSync, sourceLocation: sourceLocation)
        await yieldUntil({ barrier.waiterCount == 1 }, sourceLocation: sourceLocation)
        return barrier
    }
}

/// The coordinator's final `/close` goes out only after the syncer's report in flight for the
/// session returned, or the close wait timed out, so the close is normally the server's last word
/// on it (#337).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProgressSyncCloseOrderTests {
    /// With `queueAnother`, a pause queued a second report behind the held one; the close
    /// skips it (its session is gone) rather than waiting for it to be sent.
    @Test(arguments: [false, true])
    func theFinalCloseWaitsForTheReportInFlight(queueAnother: Bool) async throws {
        let s = try SyncHarness()
        let response = Gate()
        defer { response.open() }
        s.service.state.withLock { $0.syncGates = [response] }
        let log = HandoffLog(s)
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15, settling: false)
        await s.service.waitForSyncs(1)
        if queueAnother { s.coordinator.pause() }

        s.coordinator.stop()
        let barrier = try await log.heldClose()
        #expect(s.h.service.closes.isEmpty)

        response.open()
        await s.coordinator.waitForPendingCloses()
        #expect(barrier.result != nil)
        #expect(s.h.service.closes == ["a-1"])
        #expect(s.service.reports.count == 1)
        await s.settle()
    }

    /// Nothing in flight: the close doesn't wait.
    @Test func aCloseWithNoReportInFlightGoesOutAtOnce() async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15)
        s.coordinator.stop()
        await s.coordinator.waitForPendingCloses()
        #expect(s.h.service.closes == ["a-1"])
        await s.settle()
    }

    /// A report that never returns holds the close back only for the close wait.
    @Test func aStalledReportHoldsTheCloseOnlyUntilTheTimeout() async throws {
        let s = try SyncHarness()
        let response = Gate()
        defer { response.open() }
        s.service.state.withLock { $0.syncGates = [response] }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15, settling: false)
        await s.service.waitForSyncs(1)
        s.h.sleep.elapsesImmediately = true

        s.coordinator.stop()
        await yieldUntil { s.h.service.closes == ["a-1"] }

        #expect(s.h.sleep.durations == [PlaybackCoordinator.closeWaitTimeout])
        #expect(s.service.log == ["sync 1"])
        response.open()
        await s.settle()
    }

    /// Only a report in flight counts: one queued behind a held drain is skipped once its session
    /// closed, so the close doesn't wait for the drain.
    @Test func aReportQueuedBehindAHeldDrainDoesNotHoldTheClose() async throws {
        let s = try SyncHarness()
        let entered = Gate()
        let response = Gate()
        defer { response.open() }
        s.service.state.withLock {
            $0.patchStarted = entered
            $0.patchGates = [response]
        }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 5)
        try await s.store.recordEdit(ActiveRefreshFixture.edit(), for: s.h.key("b"), now: s.h.clock.now)
        let drain = Task { await s.syncer.drainPendingProgress() }
        await entered.wait()
        s.coordinator.pause()

        s.coordinator.stop()
        await yieldUntil { s.h.service.closes == ["a-1"] }

        #expect(s.service.reports.isEmpty)
        response.open()
        await drain.value
        await s.settle()
        #expect(s.service.reports.isEmpty)
    }

    /// Switching items with the old report held: if it returns within the close wait, the old
    /// session closes after it and before the next `/play`.
    @Test func aSwitchClosesTheOldSessionAfterItsReport() async throws {
        let s = try SyncHarness()
        let response = Gate()
        defer { response.open() }
        s.service.state.withLock { $0.syncGates = [response] }
        let log = HandoffLog(s)
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15, settling: false)
        await s.service.waitForSyncs(1)

        let switching = Task { await s.coordinator.play(itemID: "b") }
        _ = try await log.heldClose()
        #expect(s.h.service.log == ["start a"])
        response.open()
        await switching.value
        await s.settle()

        #expect(s.h.service.log == ["start a", "close a-1", "close a-1 done", "start b"])
        #expect(s.service.reports.count == 1)
    }

    /// A 404 answered while its session is closing, before the next session starts, neither
    /// abandons the next session nor drains.
    @Test func a404AnsweredDuringTheCloseLeavesTheNextSessionAlone() async throws {
        let s = try SyncHarness()
        let response = Gate()
        defer { response.open() }
        s.service.state.withLock {
            $0.syncErrors = [.notFound]
            $0.syncGates = [response]
        }
        let log = HandoffLog(s)
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15, settling: false)
        await s.service.waitForSyncs(1)

        let switching = Task { await s.coordinator.play(itemID: "b") }
        _ = try await log.heldClose()
        response.open()
        await switching.value
        await s.settle()
        #expect(s.service.log == ["sync 1", "sync 1 done"])

        s.coordinator.pause()
        await s.settle()
        #expect(s.service.state.withLock { $0.syncs.map(\.id) } == ["a-1", "b-2"])
    }
}
