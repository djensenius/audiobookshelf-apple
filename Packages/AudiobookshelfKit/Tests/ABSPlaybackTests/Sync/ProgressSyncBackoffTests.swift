import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// `/sync` answered with a server error backs off; a session the server forgot is reported by
/// PATCH (#171, L3).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProgressSyncBackoffTests {
    private static func status(_ code: Int) -> APIError { .http(status: code, message: nil) }

    /// A 5xx may have reached the session handler, so its listening time is dropped, never
    /// counted twice; 408 and 429 turned the request away first, so it rides with the next report.
    @Test(arguments: [
        (500, [15.0, 20, 30]), (503, [15, 20, 30]), (408, [15, 35, 65]), (429, [15, 35, 65]),
    ])
    func serverErrorsBackOff(code: Int, listened: [Double]) async throws {
        let s = try SyncHarness()
        s.service.state.withLock { $0.syncErrors = [Self.status(code), Self.status(code)] }
        await s.coordinator.play(itemID: "a")

        // t = 15: the report fails, and the next waits until t = 30.
        await s.play(for: 15)
        #expect(s.service.reports.count == 1)

        // A pause inside the backoff saves the position but sends nothing.
        await s.play(for: 5)
        s.coordinator.pause()
        await s.settle()
        #expect(s.service.reports.count == 1)
        let paused = try #require(try await s.store.progress(for: s.h.key("a")))
        #expect(paused.currentTime == 20 && paused.needsServerSync)

        // t = 35: the next report fails again and waits 30 s.
        await s.coordinator.resume()
        await s.play(for: 15)
        #expect(s.service.reports.count == 2)
        // t = 50 is inside the backoff; t = 65 sends and succeeds.
        await s.play(for: 15)
        #expect(s.service.reports.count == 2)
        await s.play(for: 15)

        #expect(s.service.reports.map(\.currentTime) == [15, 35, 65])
        #expect(s.service.reports.map(\.timeListened) == listened)
        // Success resets the backoff: the regular cadence resumes.
        await s.play(for: 15)
        #expect(s.service.reports.map(\.currentTime) == [15, 35, 65, 80])
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == false)
    }

    /// The failure answers half a second after the report, so the backoff ends at t = 30.5; the
    /// tick held back at t = 30 must not postpone the report to t = 45.
    @Test func aReportHeldBackByTheBackoffGoesOutWhenItEnds() async throws {
        let s = try SyncHarness()
        let response = Gate()
        s.service.state.withLock {
            $0.syncErrors = [Self.status(500)]
            $0.syncGates = [response]
        }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 14.5)
        await s.play(for: 0.5, settling: false)
        await s.service.waitForSyncs(1)
        await s.play(for: 0.5, settling: false)
        response.open()
        await s.settle()

        await s.play(for: 15)

        #expect(s.service.reports.map(\.currentTime) == [15, 30.5])
    }

    @Test func aNewSessionStartsWithoutTheBackoff() async throws {
        let s = try SyncHarness()
        s.service.state.withLock { $0.syncErrors = [Self.status(500)] }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15)

        await s.coordinator.play(itemID: "b")
        s.coordinator.pause()
        await s.settle()

        #expect(s.service.state.withLock { $0.syncs.map(\.id) } == ["a-1", "b-2"])
    }

    @Test(arguments: [408, 429, 502])
    func zeroDeltaServerErrorStillBacksOff(code: Int) async throws {
        let s = try SyncHarness()
        s.service.state.withLock { $0.syncErrors = [Self.status(code)] }
        await s.coordinator.play(itemID: "a")
        s.coordinator.pause()
        await s.settle()
        #expect(s.service.reports.map(\.timeListened) == [0])

        await s.coordinator.seek(to: 500)
        await s.settle()
        #expect(s.service.reports.count == 1)
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == 500)
    }

    @Test func otherFailuresDoNotBackOff() async throws {
        let s = try SyncHarness()
        s.service.state.withLock { $0.syncErrors = [.timedOut] }
        await s.coordinator.play(itemID: "a")
        s.coordinator.pause()
        await s.settle()
        await s.coordinator.seek(to: 500)
        await s.settle()
        #expect(s.service.reports.map(\.currentTime) == [0, 500])
    }

    @Test func flushIgnoresTheBackoff() async throws {
        let s = try SyncHarness()
        s.service.state.withLock { $0.syncErrors = [Self.status(500)] }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15)
        await s.play(for: 2)
        #expect(s.service.reports.count == 1)

        await s.syncer.flush()

        #expect(s.service.reports.map(\.currentTime) == [15, 17])
        #expect(s.service.reports.last?.timeListened == 2)
    }

    @Test func backoffDoublesUpToTheCap() {
        let delays = [1, 2, 3, 4, 5, 6, 100, Int.max].map(ProgressSyncer.syncBackoff(afterFailures:))
        #expect(delays == [15, 30, 60, 120, 240, 300, 300, 300])
    }

    /// The server restarts mid-session and forgets it: no more `/sync` to the dead session, and
    /// each later trigger PATCHes the saved position instead.
    @Test func aSessionTheServerForgotReportsItsPositionByPatch() async throws {
        let s = try SyncHarness()
        let model = ReconciliationSessionModel(clock: s.h.clock)
        let client = SessionModelClient(model: model)
        s.h.service.state.withLock { $0.sessionClient = client }
        s.service.state.withLock { $0.sessionClient = client }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15)
        #expect(s.service.state.withLock { $0.syncs.count } == 1)

        await model.restart()
        await s.play(for: 15)
        // The 404 is answered by draining the t = 30 position.
        #expect(s.service.state.withLock { $0.syncs.count } == 2)
        #expect(s.service.patches.last == .init(itemID: "a", update: SyncHarness.audio(30)))

        await s.play(for: 15)
        s.coordinator.pause()
        await s.settle()

        #expect(s.service.state.withLock { $0.syncs.count } == 2)
        #expect(s.service.patches.last == .init(itemID: "a", update: SyncHarness.audio(45)))
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == false)
    }

    /// The server applied nothing, so the report's evidence isn't kept as possibly applied.
    @Test func aForgottenSessionsReportIsNotDelivered() async throws {
        let s = try SyncHarness()
        let patch = Gate()
        let patchStarted = Gate()
        s.service.state.withLock {
            $0.syncErrors = [.notFound]
            $0.patchGates = [patch]
            $0.patchStarted = patchStarted
        }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15, settling: false)
        await patchStarted.wait()

        let row = try #require(try await s.store.progress(for: s.h.key("a")))
        patch.open()
        await s.settle()
        #expect(row.unacknowledgedSends.allSatisfy { $0.sessionAudio == nil })
    }

    @Test func flushOnAForgottenSessionOnlyPatches() async throws {
        let s = try SyncHarness()
        s.service.state.withLock { $0.syncErrors = [.notFound] }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15)
        await s.play(for: 2)

        await s.syncer.flush()

        #expect(s.service.reports.count == 1)
        #expect(s.service.patches.map(\.update) == [SyncHarness.audio(15), SyncHarness.audio(17)])
    }

    /// A 404 that answers an ended session's report must not abandon the next session.
    @Test func aLate404LeavesTheNextSessionAlone() async throws {
        let s = try SyncHarness()
        let response = Gate()
        s.service.state.withLock {
            $0.syncErrors = [.notFound]
            $0.syncGates = [response]
        }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15, settling: false)
        await s.service.waitForSyncs(1)
        await s.coordinator.play(itemID: "b")
        response.open()
        await s.settle()
        #expect(s.service.log == ["sync 1", "sync 1 done"])

        s.coordinator.pause()
        await s.settle()

        #expect(s.service.state.withLock { $0.syncs.map(\.id) } == ["a-1", "b-2"])
    }

    /// The forgotten session's item is gone too: its row is rejected once, not on every trigger.
    @Test func aRejectedRowStopsTheForgottenSessionsPatches() async throws {
        let s = try SyncHarness()
        s.service.state.withLock {
            $0.syncErrors = [.notFound]
            $0.patchErrors = [.notFound]
        }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15)
        #expect(s.service.patches.count == 1)

        await s.play(for: 15)
        s.coordinator.pause()
        await s.settle()

        #expect(s.service.reports.count == 1 && s.service.patches.count == 1)
        let row = try #require(try await s.store.progress(for: s.h.key("a")))
        #expect(row.currentTime == 30 && row.needsServerSync)
        // An explicit drain still tries the row.
        await s.syncer.flush()
        #expect(s.service.patches.map(\.update) == [SyncHarness.audio(15), SyncHarness.audio(30)])
    }
}
