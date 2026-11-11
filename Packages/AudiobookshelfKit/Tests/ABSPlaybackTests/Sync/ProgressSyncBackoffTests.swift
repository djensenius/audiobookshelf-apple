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

    @Test func serverErrorsBackOffAndKeepListeningTimeForTheNextReport() async throws {
        let s = try SyncHarness()
        s.service.state.withLock { $0.syncErrors = [Self.status(500), Self.status(503)] }
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

        // t = 35: the next report carries the paused 5 s too, fails again and waits 30 s.
        await s.coordinator.resume()
        await s.play(for: 15)
        #expect(s.service.reports.count == 2)
        // t = 50 is inside the backoff; t = 65 sends and succeeds.
        await s.play(for: 15)
        #expect(s.service.reports.count == 2)
        await s.play(for: 15)

        #expect(s.service.reports.map(\.currentTime) == [15, 35, 65])
        #expect(s.service.reports.map(\.timeListened) == [15, 20, 30])
        // Success resets the backoff: the regular cadence resumes.
        await s.play(for: 15)
        #expect(s.service.reports.map(\.currentTime) == [15, 35, 65, 80])
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == false)
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
}
