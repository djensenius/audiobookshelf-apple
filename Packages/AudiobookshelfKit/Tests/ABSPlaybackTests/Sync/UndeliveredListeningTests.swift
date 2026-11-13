import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// #383 (ADR 0007): listening time the server never applied, whose session can't send it any
/// more, is reported once by the media's next session; time that may have applied is dropped,
/// never counted twice. In ``CloseRetryFixture`` reports go out every 15 s, the close wait
/// elapses at once, and the stub server stores each session's listening time.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct UndeliveredListeningTests {
    /// The server restarts mid-session, so session 1's second report (15 s) meets 404 and the
    /// session is abandoned; its close, with the 5 s played since, meets 404 too. The server
    /// applied neither, so session 2 of the same media reports both with its own 15 s. The
    /// abandoned session itself never takes the carried time: it can't report it.
    @Test func a404dReportsTimeGoesToTheMediasNextSession() async throws {
        let f = try CloseRetryFixture()
        await f.s.coordinator.play(itemID: "a")
        await f.s.play(for: 15)
        await f.model.restart()
        await f.s.play(for: 15)
        #expect(f.s.syncer.closeQueue.carried.map(\.seconds) == [15])

        await f.s.play(for: 5)
        f.s.coordinator.stop()
        await f.s.coordinator.waitForPendingCloses()
        await f.s.settle()
        await f.s.syncer.closeQueue.waitForCaptures()
        #expect(f.s.syncer.closeQueue.carried.map(\.seconds) == [20])

        await f.s.coordinator.play(itemID: "a")
        #expect(f.s.syncer.closeQueue.carried.isEmpty)
        await f.s.play(for: 15)

        // Every second played (15 + 15 + 5 + 15) counts once.
        #expect(try await f.listened("session-1") == 15)
        #expect(try await f.listened("session-2") == 35)
        #expect(f.s.service.closes.isEmpty)
        #expect(try await f.queued().isEmpty)
    }

    /// Session 1's report (15 s) is still out when the session closes, so its close carries only
    /// the 5 s played after it. The report then fails without the server applying it (404, no
    /// connection, 429): its 15 s go to the media's next session, whether that session loaded
    /// before the failure or loads after. One that may have applied (a timeout) is dropped.
    @Test(
        arguments: [APIError.notFound, .network(.cannotConnectToHost), .http(status: 429, message: nil), .timedOut],
        [false, true])
    func aClosedSessionsUndeliveredReportGoesToTheMediasNextSession(error: APIError, nextLoadsFirst: Bool)
        async throws
    {
        let f = try CloseRetryFixture()
        let response = Gate()
        defer { response.open() }
        f.s.service.state.withLock {
            $0.syncErrors = [error]
            $0.syncGates = [response]
        }
        await f.s.coordinator.play(itemID: "a")
        await f.s.play(for: 15, settling: false)
        await f.s.service.waitForSyncs(1)
        await f.s.play(for: 5, settling: false)
        f.s.coordinator.stop()
        await f.s.coordinator.waitForPendingCloses()
        await f.s.syncer.closeQueue.waitForCaptures()
        if nextLoadsFirst { await f.s.coordinator.play(itemID: "a") }

        response.open()
        await f.s.settle()
        if !nextLoadsFirst { await f.s.coordinator.play(itemID: "a") }
        #expect(f.s.syncer.closeQueue.carried.isEmpty)
        await f.s.play(for: 15)

        let carried: Double = error == .timedOut ? 0 : 15
        #expect(try await f.listened("session-1") == 5)
        #expect(try await f.listened("session-2") == 15 + carried)
        #expect(f.s.service.reports.map(\.timeListened) == [15, 15 + carried])
    }

    /// A close that admission skips (another device saved newer progress) is never resent: its
    /// session's stored record decides, as for a 404. Never applied, its 5 s go to the media's
    /// next session; applied with its response lost, the record counts them, so they're
    /// dropped; the item gone, nothing tells, so they're dropped too.
    @Test(arguments: ["not applied", "applied", "item gone"])
    func aSkippedCloseIsSettledByTheStoredRecord(record: String) async throws {
        let f = try CloseRetryFixture()
        try await f.stopSessionOne(record == "applied" ? .appliedResponseLost : .unapplied)
        f.s.h.clock.advance(by: 10)
        let tablet = SessionModelClient(model: f.model, deviceID: "tablet")
        let session = try await f.model.start(tablet, itemID: "a", episodeID: nil)
        try await f.model.sync(
            tablet, id: session.id,
            report: #require(PlaybackSyncReport(currentTime: 900, timeListened: 30, duration: 3600)))
        if record == "item gone" { f.s.service.state.withLock { $0.recordsErrors = [APIError.notFound] } }

        await f.drainWhenDue()

        #expect(f.verdicts == [.skip(.positionSuperseded)])
        #expect(f.s.service.closes.isEmpty)
        #expect(f.s.service.log.filter { $0 == "records a" }.count == 1)
        #expect(try await f.queued().isEmpty)
        #expect(try await f.listened("session-1") == (record == "applied" ? 20 : 15))
        #expect(f.s.syncer.closeQueue.carried.map(\.seconds) == (record == "not applied" ? [5] : []))

        await f.s.coordinator.play(itemID: "a")
        await f.s.play(for: 15)
        #expect(try await f.listened("session-3") == (record == "not applied" ? 20 : 15))
    }
}
