import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

@MainActor
struct ProgressSyncerTests {
    // MARK: Cadence

    @Test func reportsEvery15SecondsOfPlayInWallClockTime() async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a")

        await s.play(for: 14.5)
        await s.settle()
        #expect(s.service.reports.isEmpty)
        #expect(try await s.store.progress(for: s.h.key("a")) == nil)

        await s.play(for: 0.5)
        await s.settle()
        #expect(
            s.service.reports == [try #require(PlaybackSyncReport(currentTime: 15, timeListened: 15, duration: 3600))])
        #expect(s.service.state.withLock { $0.syncs.map(\.id) } == ["a-1"])

        // At 2× the media moves 30 s, but 15 s of listening is credited.
        await s.play(for: 15, rate: 2)
        await s.settle()
        #expect(s.service.reports.count == 2)
        #expect(s.service.reports.last?.timeListened == 15)
        #expect(s.service.reports.last?.currentTime == 45)
        // Reports are saved first; the PATCH acknowledgement leaves a clean, current row.
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == 45)
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == false)
    }

    @Test func pauseSeekChapterChangeAndEndReportAtOnce() async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a", startTime: 990)

        await s.play(for: 4)
        s.coordinator.pause()
        await s.settle()
        #expect(s.service.reports.map(\.currentTime) == [994])
        #expect(s.service.reports.map(\.timeListened) == [4])

        await s.coordinator.seek(to: 500)
        await s.settle()
        #expect(s.service.reports.last == PlaybackSyncReport(currentTime: 500, timeListened: 0, duration: 3600))

        await s.coordinator.resume()
        await s.coordinator.seek(to: 999)
        await s.settle()
        // Chapter "One" ends at 1000.
        await s.play(for: 0.5)
        await s.settle()
        #expect(s.service.reports.count == 3)
        await s.play(for: 0.5)
        await s.settle()
        #expect(s.service.reports.map(\.currentTime) == [994, 500, 999, 1000])
        #expect(s.service.reports.last?.timeListened == 1)

        s.h.engine.finish()
        await s.settle()
        #expect(s.service.reports.map(\.currentTime) == [994, 500, 999, 1000, 3600])
    }

    @Test func pausedTicksAndSuspensionGapsCreditAtMostOneInterval() async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a")
        await s.play(for: 2)
        s.coordinator.pause()
        await s.settle()

        // Ticks while paused credit nothing.
        s.h.clock.advance(by: 10)
        s.h.engine.onEvent?(.tick(s.h.engine.currentTime))
        await s.coordinator.resume()
        // A 60 s gap between ticks (a suspension) credits one tick interval.
        s.h.clock.advance(by: 60)
        s.h.engine.currentTime += 0.5
        s.h.engine.onEvent?(.tick(s.h.engine.currentTime))
        await s.syncer.flush()

        #expect(s.service.reports.map(\.timeListened).reduce(0, +) == 2.5)
    }

    @Test func flushReportsAtOnceAndWaitsForTheRequest() async throws {
        let s = try SyncHarness()
        try await s.store.recordEdit(
            ProgressEdit(audio: .init(currentTime: 50, duration: 3600, progress: 50 / 3600)), for: s.h.key("b"),
            now: s.h.clock.now)
        await s.coordinator.play(itemID: "a")
        await s.play(for: 7)

        await s.syncer.flush()

        #expect(
            s.service.reports == [try #require(PlaybackSyncReport(currentTime: 7, timeListened: 7, duration: 3600))])
        #expect(s.service.patches.map(\.itemID) == ["b", "a"])
        #expect(try await s.store.pendingSync(for: s.h.connectionID).isEmpty)
    }

    @Test func frozenMediaTimeCreditsNothing() async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a")
        await s.play(for: 2)

        // Playing, but the media doesn't move (buffering): wall time passes, nothing is credited.
        for _ in 0..<6 {
            s.h.clock.advance(by: 0.5)
            s.h.engine.onEvent?(.tick(s.h.engine.currentTime))
        }
        #expect(s.coordinator.isPlaying)
        await s.syncer.flush()

        #expect(s.service.reports.map(\.timeListened) == [2])
    }

    @Test func seekWhilePlayingCreditsTheTimeBeforeIt() async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a")
        await s.play(for: 2)

        s.h.clock.advance(by: 0.25)
        await s.coordinator.seek(to: 500)
        await s.settle()
        s.coordinator.pause()
        await s.settle()

        #expect(s.service.reports.map(\.currentTime) == [500, 500])
        #expect(s.service.reports.map(\.timeListened) == [2.25, 0])
    }

    @Test func slowSeekWithFrozenMediaCreditsNothing() async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a")
        await s.play(for: 2)

        // The seek takes 1.8 s to land and no tick fires meanwhile.
        s.h.clock.advance(by: 1.8)
        await s.coordinator.seek(to: 500)
        await s.settle()
        s.coordinator.pause()
        await s.settle()

        #expect(s.service.reports.map(\.currentTime) == [500, 500])
        #expect(s.service.reports.map(\.timeListened) == [2, 0])
    }

    @Test func shortStallBetweenTicksIsCreditedInFull() async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a")
        await s.play(for: 1)

        // 1.5 s between ticks is a stall, not a suspension (the cap is 2 s with 0.5 s ticks).
        s.h.clock.advance(by: 1.5)
        s.h.engine.currentTime += 1.5
        s.h.engine.onEvent?(.tick(s.h.engine.currentTime))
        await s.syncer.flush()

        #expect(s.syncer.maxTickGap == 2)
        #expect(s.service.reports.map(\.timeListened) == [2.5])
    }

    @Test func reportsAreSentOneAtATime() async throws {
        let s = try SyncHarness()
        let gate = Gate()
        s.service.state.withLock { $0.syncGates = [gate] }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15, settling: false)
        await s.service.waitForSyncs(1)

        // While report 1 is held, a seek and a pause queue one follow-up report.
        s.h.clock.advance(by: 0.25)
        await s.coordinator.seek(to: 100)
        s.coordinator.pause()
        #expect(s.service.log == ["sync 1"])

        gate.open()
        await s.settle()
        #expect(s.service.log == ["sync 1", "sync 1 done", "patch a", "sync 2", "sync 2 done"])
        #expect(
            s.service.reports == [
                try #require(PlaybackSyncReport(currentTime: 15, timeListened: 15, duration: 3600)),
                try #require(PlaybackSyncReport(currentTime: 100, timeListened: 0.25, duration: 3600)),
            ])
    }

    // MARK: Failures and the durable queue

    @Test func failedReportWritesProgressAndResendsTimeThatNeverLeft() async throws {
        let s = try SyncHarness()
        s.service.state.withLock { $0.syncErrors = [.network(.cannotConnectToHost)] }
        await s.coordinator.play(itemID: "a")

        await s.play(for: 15)
        await s.settle()
        let row = try #require(try await s.store.progress(for: s.h.key("a")))
        #expect(row.needsServerSync)
        #expect(row.audioDirty && !row.finishedDirty && !row.ebookDirty)
        #expect(row.currentTime == 15)
        #expect(row.duration == 3600)
        #expect(s.service.patches.isEmpty)

        // Back online: the time is reported once, and the row is brought up to date, then sent.
        await s.play(for: 15)
        await s.settle()
        #expect(s.service.reports.map(\.timeListened) == [15, 30])
        #expect(s.service.patches == [.init(itemID: "a", update: SyncHarness.audio(30))])
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == false)
    }

    @Test func ambiguousFailureDropsItsListeningTime() async throws {
        let s = try SyncHarness()
        s.service.state.withLock { $0.syncErrors = [.timedOut] }
        await s.coordinator.play(itemID: "a")

        await s.play(for: 30)
        await s.settle()

        #expect(s.service.reports.map(\.timeListened) == [15, 15])
        #expect(s.service.patches == [.init(itemID: "a", update: SyncHarness.audio(30))])
    }

    @Test func failedPatchIsRetriedOnTheNextDrain() async throws {
        let s = try SyncHarness()
        s.service.state.withLock {
            $0.patchErrors = [.network(.networkConnectionLost)]
        }
        try await s.store.recordEdit(
            ProgressEdit(audio: .init(currentTime: 50, duration: 3600, progress: 50 / 3600)), for: s.h.key("a"),
            now: s.h.clock.now)

        await s.syncer.drainPendingProgress()
        let row = try #require(try await s.store.progress(for: s.h.key("a")))
        #expect(row.needsServerSync)
        #expect(row.lastSyncError == "network")

        await s.syncer.drainPendingProgress()
        #expect(s.service.patches == Array(repeating: .init(itemID: "a", update: SyncHarness.audio(50)), count: 2))
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == false)
    }

    /// A server error on one row's PATCH moves on to the next row; a failure that would hit
    /// every request (time-out, network, auth) stops the drain.
    @Test(arguments: [
        (APIError.http(status: 500, message: nil), 2),
        (.notFound, 2),
        (.timedOut, 1),
        (.network(.networkConnectionLost), 1),
        (.sessionExpired, 1),
    ])
    func drainSkipsARowOrStops(error: APIError, patchesSent: Int) async throws {
        let s = try SyncHarness()
        s.service.state.withLock { $0.patchErrors = [error] }
        for item in ["a", "b"] {
            try await s.store.recordEdit(
                ProgressEdit(audio: .init(currentTime: 50, duration: 3600, progress: 50 / 3600)), for: s.h.key(item),
                now: s.h.clock.now)
        }

        await s.syncer.drainPendingProgress()

        #expect(s.service.patches.count == patchesSent)
        let pending = try await s.store.pendingSync(for: s.h.connectionID)
        #expect(pending.count == 3 - patchesSent)
        #expect(pending.first?.key.libraryItemId == s.service.patches.first?.itemID)
    }

    @Test func aSendWithNoGroupIsNotAPatch() {
        #expect(ProgressSyncer.update(for: ProgressSend()) == nil)
        #expect(
            ProgressSyncer.update(
                for: ProgressSend(ebook: .init(ebookLocation: nil, ebookProgress: nil, editedAt: Date())))
                == .ebook(location: nil, progress: 0))
    }

    @Test func relaunchDrainsEachGroupAsItsOwnPatchInOrder() async throws {
        let container = try DataStack(location: .inMemory).container
        let connectionID = UUID()
        let key = MediaKey(serverConnectionID: connectionID, libraryItemId: "a", episodeId: "e1")
        let editedAt = Date(timeIntervalSince1970: 1_800_000_000.1234)
        try await LocalProgressStore(modelContainer: container).recordEdit(
            ProgressEdit(
                audio: .init(currentTime: 3595, duration: 3600, progress: 3595 / 3600), isFinished: true,
                ebook: .init(location: "epubcfi(/6/4)", progress: nil)), for: key, now: editedAt)
        try await LocalProgressStore(modelContainer: container).recordEdit(
            ProgressEdit(isFinished: true), for: MediaKey(serverConnectionID: UUID(), libraryItemId: "x"))

        // A new store and syncer over the same in-memory container; disk reopening is tested separately.
        let s = try SyncHarness(
            progressStore: LocalProgressStore(modelContainer: container), connectionID: connectionID)
        await s.syncer.drainPendingProgress()

        #expect(
            s.service.patches == [
                .init(
                    itemID: "a", episodeID: "e1",
                    update: .audio(currentTime: 3595, duration: 3600, progress: 3595 / 3600)),
                .init(itemID: "a", episodeID: "e1", update: .finished(true, at: editedAt)),
                .init(itemID: "a", episodeID: "e1", update: .ebook(location: "epubcfi(/6/4)", progress: 0)),
            ])
        for patch in s.service.patches {
            let body = try #require(
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(patch.update)) as? [String: Any])
            #expect(body["lastUpdate"] == nil)
        }
        #expect(try await s.store.pendingSync(for: connectionID).isEmpty)
    }

    // MARK: Close

    @Test func finalCloseCarriesTheUnreportedTime() async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a")
        await s.play(for: 20)
        await s.settle()

        await s.coordinator.play(itemID: "b")
        await s.play(for: 4)
        s.coordinator.stop()
        await s.coordinator.waitForPendingCloses()
        await s.settle()

        let closes = s.h.service.state.withLock { $0.closeReports }
        #expect(closes["a-1"] == PlaybackSyncReport(currentTime: 20, timeListened: 5, duration: 3600))
        #expect(closes["b-2"] == PlaybackSyncReport(currentTime: 4, timeListened: 4, duration: 3600))
        #expect(s.service.reports.map(\.timeListened) == [15])
        #expect(try await s.store.pendingSync(for: s.h.connectionID).isEmpty)
    }

    @Test func closeBringsAPendingRowUpToDate() async throws {
        let s = try SyncHarness()
        s.service.state.withLock { $0.syncErrors = [.network(.cannotConnectToHost)] }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15)
        await s.settle()
        await s.play(for: 5)
        s.coordinator.stop()
        await s.coordinator.waitForPendingCloses()
        await s.settle()

        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == 20)
        // The 15 s the failed report never delivered, plus the 5 s since.
        let closes = s.h.service.state.withLock { $0.closeReports }
        #expect(closes["a-1"] == PlaybackSyncReport(currentTime: 20, timeListened: 20, duration: 3600))
    }

    @Test func detachStopsFollowing() async throws {
        let s = try SyncHarness()
        s.syncer.detach()
        #expect(s.coordinator.finalCloseReport == nil)
        await s.coordinator.play(itemID: "a")
        await s.play(for: 30)
        await s.settle()
        #expect(s.service.reports.isEmpty)
    }

    @Test func detachSkipsQueuedRequestsAndLetsTheOneInFlightFinish() async throws {
        let s = try SyncHarness()
        try await s.store.recordEdit(
            ProgressEdit(audio: .init(currentTime: 50, duration: 3600, progress: 50 / 3600)), for: s.h.key("b"),
            now: s.h.clock.now)
        let gate = Gate()
        s.service.state.withLock { $0.syncGates = [gate] }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15, settling: false)
        await s.service.waitForSyncs(1)
        await s.coordinator.seek(to: 100)

        s.syncer.detach()
        gate.open()
        await s.settle()

        #expect(s.service.log == ["sync 1", "sync 1 done"])
        #expect(s.service.patches.isEmpty)
        let pending = try await s.store.pendingSync(for: s.h.connectionID)
        #expect(
            Dictionary(uniqueKeysWithValues: pending.map { ($0.key.libraryItemId, $0.currentTime) }) == [
                "a": 100, "b": 50,
            ])
    }

    // MARK: Errors

    /// Only failures that prove the request never reached the server carry its listening time.
    @Test(arguments: [
        (APIError.network(.cannotFindHost), true),
        (.network(.dnsLookupFailed), true),
        (.network(.cannotConnectToHost), true),
        (.network(.secureConnectionFailed), true),
        (.network(.internationalRoamingOff), true),
        (.network(.appTransportSecurityRequiresSecureConnection), true),
        (.notAuthenticated, true),
        (.sessionExpired, true),
        (.unauthorized(message: nil), true),
        (.forbidden(message: "no"), true),
        (.invalidURL, true),
        (.encoding("bad"), true),
        (.network(.notConnectedToInternet), false),
        (.network(.dataNotAllowed), false),
        (.network(.callIsActive), false),
        (.network(.networkConnectionLost), false),
        (.network(.cancelled), false),
        (.timedOut, false),
        (.redirectRefused(status: 302), false),
        (.invalidResponse, false),
        (.notFound, false),
        (.http(status: 500, message: nil), false),
        (.decoding("bad"), false),
    ])
    func neverReachedServer(error: APIError, expected: Bool) {
        #expect(ProgressSyncer.neverReachedServer(error) == expected)
    }

    @Test func cancellationIsAmbiguous() {
        #expect(!ProgressSyncer.neverReachedServer(CancellationError()))
    }
}
