import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// The coordinator's final `/close` goes out only after the syncer's report in flight for the
/// session returned, so the close is the server's last word on it (#337).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProgressSyncCloseOrderTests {
    /// With `queueAnother`, a pause queued a second report behind the held one; the close
    /// skips it (its session is gone) rather than waiting for it to be sent.
    @Test(arguments: [false, true])
    func theFinalCloseWaitsForTheReportInFlight(queueAnother: Bool) async throws {
        let s = try SyncHarness()
        let response = Gate()
        s.service.state.withLock { $0.syncGates = [response] }
        var handoffs: [PlaybackCloseHandoff] = []
        let finalReport = s.coordinator.finalCloseReport
        s.coordinator.finalCloseReport = { closing in
            let handoff = finalReport?(closing)
            if let handoff { handoffs.append(handoff) }
            return handoff
        }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15, settling: false)
        await s.service.waitForSyncs(1)
        if queueAnother { s.coordinator.pause() }

        s.coordinator.stop()
        let barrier = try #require(handoffs.first?.sessionSync)
        await yieldUntil { barrier.waiterCount == 1 }
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
}
