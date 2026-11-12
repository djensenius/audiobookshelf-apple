import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// A backed-off session reports when its backoff ends, and a drain that stopped on a failure
/// runs again, without a tick or pause to trigger it (#337).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProgressSyncWakeTests {
    private static func status(_ code: Int) -> APIError { .http(status: code, message: nil) }

    @Test func aPausedSessionReportsWhenItsBackoffEnds() async throws {
        let s = try SyncHarness()
        s.service.state.withLock { $0.syncErrors = [Self.status(500)] }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 5)
        s.coordinator.pause()
        await s.settle()
        #expect(s.service.reports.count == 1)

        let wake = try #require(s.syncer.syncWake)
        s.h.clock.advance(by: 15)
        s.sleeper.fire()
        await wake.value
        await s.settle()

        #expect(s.sleeper.delays == [15])
        #expect(s.service.reports.map(\.currentTime) == [5, 5])
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == false)
        #expect(s.syncer.syncWake == nil)
    }

    /// The wake waits as long as the backoff: twice as long after a second failure.
    @Test func eachFailedReportReschedulesTheWake() async throws {
        let s = try SyncHarness()
        s.service.state.withLock { $0.syncErrors = [Self.status(503), Self.status(429)] }
        await s.coordinator.play(itemID: "a")
        s.coordinator.pause()
        await s.settle()
        let first = try #require(s.syncer.syncWake)
        s.h.clock.advance(by: 15)
        s.sleeper.fire()
        await first.value
        await s.settle()
        let second = try #require(s.syncer.syncWake)
        s.h.clock.advance(by: 30)
        s.sleeper.fire()
        await second.value
        await s.settle()

        #expect(s.sleeper.delays == [15, 30])
        #expect(s.service.reports.count == 3)
        #expect(s.syncer.syncWake == nil)
    }

    @Test(arguments: [false, true])
    func detachingOrQuiescingCancelsTheWakes(detach: Bool) async throws {
        let s = try SyncHarness()
        s.service.state.withLock {
            $0.syncErrors = [Self.status(500)]
            $0.patchErrors = [Self.status(500)]
        }
        await s.coordinator.play(itemID: "a")
        s.coordinator.pause()
        await s.settle()
        await s.syncer.drainPendingProgress()
        let wakes = try [#require(s.syncer.syncWake), #require(s.syncer.drainWake)]

        await yieldUntil { s.sleeper.waitingCount == 2 }
        if detach { s.syncer.detach() } else { s.syncer.quiesceTransport() }
        // Cancelled, not just ignored when they fire: their sleeps ended at once.
        #expect(wakes.allSatisfy { $0.isCancelled })
        #expect(s.sleeper.waitingCount == 0)
        #expect(s.syncer.syncWake == nil && s.syncer.drainWake == nil)
        s.h.clock.advance(by: 15)
        s.sleeper.fire()
        for wake in wakes { await wake.value }
        await s.settle()
        #expect(s.service.reports.count == 1 && s.service.patches.count == 1)
    }

    /// The wake falls due with the tick that sends the next report. With that report in flight,
    /// the wake adds nothing: a failure backs off afresh, and a success needs no second report.
    @Test(arguments: [true, false])
    func aWakeWithAReportInFlightSendsNoOther(fails: Bool) async throws {
        let s = try SyncHarness()
        let response = Gate()
        defer { response.open() }
        let first = Gate()
        first.open()
        s.service.state.withLock {
            $0.syncErrors = fails ? [Self.status(500), Self.status(500)] : [Self.status(500)]
            $0.syncGates = [first, response]
        }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15)
        let wake = try #require(s.syncer.syncWake)
        // t = 30: the backoff ends and the tick's report is held in flight.
        await s.play(for: 15, settling: false)
        await s.service.waitForSyncs(2)
        s.sleeper.fire()
        await wake.value
        response.open()
        await s.settle()

        #expect(s.service.reports.map(\.currentTime) == [15, 30])
        // Another 15 s is still inside the new 30 s backoff.
        await s.play(for: 15)
        #expect(s.service.reports.count == (fails ? 2 : 3))
        #expect((s.syncer.syncWake != nil) == fails)
        await s.settle()
    }

    /// A wake scheduled before the account switched sends nothing after it.
    @Test func aWakeFromBeforeAnAccountSwitchSendsNothing() async throws {
        let s = try SyncHarness()
        s.service.state.withLock { $0.syncErrors = [Self.status(503)] }
        await s.coordinator.play(itemID: "a")
        s.coordinator.pause()
        await s.settle()
        let wake = try #require(s.syncer.syncWake)

        s.coordinator.stop(reason: .accountSwitch)
        _ = try await s.coordinator.waitForClose()
        s.h.clock.advance(by: 15)
        s.sleeper.fire()
        await wake.value
        await s.settle()

        #expect(wake.isCancelled)
        #expect(s.service.reports.count == 1 && s.service.patches.isEmpty)
    }

    /// A drain whose PATCH failed runs again after a backoff that doubles while it keeps
    /// failing; a clean drain ends the retries.
    @Test func aFailedDrainRetriesAfterABackoff() async throws {
        let s = try SyncHarness()
        s.service.state.withLock { $0.patchErrors = [Self.status(500), .timedOut] }
        try await s.store.recordEdit(
            ProgressEdit(audio: .init(currentTime: 50, duration: 3600, progress: 50 / 3600)), for: s.h.key("a"),
            now: s.h.clock.now)
        await s.syncer.drainPendingProgress()

        for _ in 0..<2 {
            let wake = try #require(s.syncer.drainWake)
            s.sleeper.fire()
            await wake.value
            await s.settle()
        }

        #expect(s.sleeper.delays == [15, 30])
        #expect(s.service.patches.map(\.update) == Array(repeating: SyncHarness.audio(50), count: 3))
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == false)
        #expect(s.syncer.drainWake == nil)
    }

    /// A drain with nothing failing schedules nothing.
    @Test func aCleanDrainSchedulesNoWake() async throws {
        let s = try SyncHarness()
        try await s.store.recordEdit(
            ProgressEdit(audio: .init(currentTime: 50, duration: 3600, progress: 50 / 3600)), for: s.h.key("a"),
            now: s.h.clock.now)
        await s.syncer.drainPendingProgress()
        #expect(s.syncer.drainWake == nil && s.syncer.syncWake == nil)
        #expect(s.sleeper.delays.isEmpty)
    }
}
