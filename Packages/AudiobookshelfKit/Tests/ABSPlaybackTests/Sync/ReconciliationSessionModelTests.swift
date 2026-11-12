import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

@MainActor
struct ReconciliationSessionModelTests {
    private struct Adapters {
        let sessions: StubSessionService
        let progress: StubProgressSyncService

        init(_ model: ReconciliationSessionModel, user: String = "user", device: String = "phone") {
            let connection = UUID()
            sessions = StubSessionService(serverConnectionID: connection)
            progress = StubProgressSyncService(serverConnectionID: connection)
            let client = SessionModelClient(model: model, userID: user, deviceID: device)
            sessions.state.withLock { $0.sessionClient = client }
            progress.state.withLock { $0.sessionClient = client }
        }

        func start(_ item: String = "a", episode: String? = nil) async throws -> PlaybackSession {
            try await sessions.startSession(itemID: item, episodeID: episode)
        }

        func report(_ position: Double, _ listened: Double) throws -> PlaybackSyncReport {
            try #require(PlaybackSyncReport(currentTime: position, timeListened: listened, duration: 3600))
        }

        func patch(_ update: MediaProgressUpdate, _ item: String = "a") async throws {
            try await progress.updateProgress(itemID: item, episodeID: nil, update)
        }

        func row(_ item: String = "a") async throws -> MediaProgress {
            try #require(try await progress.fetchProgress(itemID: item, episodeID: nil))
        }
    }

    @Test func takeoverSharesReportsAcrossItemsButNotUsersOrDevices() async throws {
        let model = ReconciliationSessionModel()
        let phone = Adapters(model)
        let watch = Adapters(model, device: "watch")
        let otherUser = Adapters(model, user: "other")
        let first = try await phone.start()
        try await phone.progress.syncSession(id: first.id, report: phone.report(10, 3))
        let independent = try await watch.start()
        let other = try await otherUser.start()
        let second = try await phone.start("b")
        await #expect(throws: APIError.notFound) { try await phone.sessions.openSession(id: first.id) }
        await #expect(throws: APIError.notFound) {
            try await phone.progress.syncSession(id: first.id, report: phone.report(99, 8))
        }
        await #expect(throws: APIError.notFound) {
            try await phone.sessions.closeSession(id: first.id, report: phone.report(99, 8))
        }
        #expect(try await watch.sessions.openSession(id: independent.id).timeListening == 0)
        #expect(try await otherUser.sessions.openSession(id: other.id).timeListening == 0)
        #expect(try await phone.sessions.openSession(id: second.id).libraryItemId == "b")
        let stored = try await phone.sessions.listeningSessions(itemID: "a")
        #expect(stored.sessions.map(\.id) == [first.id])
        #expect(stored.sessions.first?.timeListening == 3 && stored.sessions.first?.currentTime == 10)
        #expect(try await otherUser.sessions.listeningSessions(itemID: "a").total == 0)
        #expect(try await phone.progress.fetchProgress(itemID: "a", episodeID: nil)?.currentTime == 10)
        _ = try await phone.start("b")
        await #expect(throws: APIError.notFound) { try await phone.sessions.openSession(id: second.id) }
    }

    @Test func startEntryApplicationAndLostResponseAreIndependent() async throws {
        let model = ReconciliationSessionModel()
        let client = Adapters(model)
        let first = try await client.start()
        try await client.progress.syncSession(id: first.id, report: client.report(10, 3))
        let request = ReconciliationSessionModel.Request(.appliedResponseLost)
        defer { request.release() }
        await model.enqueue(request, for: .start)
        let start = Task { try await client.start("b") }
        await request.arrived.wait()
        #expect(try await client.sessions.openSession(id: first.id).id == first.id)
        request.enter.open()
        await request.entered.wait()
        #expect(try await client.sessions.openSession(id: first.id).id == first.id)
        request.apply.open()
        await request.applicationFinished.wait()
        await #expect(throws: APIError.notFound) { try await client.sessions.openSession(id: first.id) }
        #expect(try await client.sessions.listeningSessions(itemID: "a").sessions.first?.timeListening == 3)
        // The takeover is observable while the new start's response is still withheld.
        request.respond.open()
        await #expect(throws: ReconciliationSessionModel.Failure.responseLost) { try await start.value }
    }

    @Test(arguments: [true, false])
    func syncApplicationIsDistinctFromResponseAndCancellation(applied: Bool) async throws {
        let model = ReconciliationSessionModel()
        let client = Adapters(model)
        let first = try await client.start()
        let request = ReconciliationSessionModel.Request(applied ? .appliedResponseLost : .unapplied)
        defer { request.release() }
        await model.enqueue(request, for: .sync)
        let sync = Task { try await client.progress.syncSession(id: first.id, report: client.report(10, 3)) }
        await request.arrived.wait()
        #expect(try await client.sessions.openSession(id: first.id).timeListening == 0)
        request.enter.open()
        await request.entered.wait()
        #expect(try await client.progress.fetchProgress(itemID: "a", episodeID: nil) == nil)
        sync.cancel()  // Cancellation is not wired to the server-application gate.
        request.apply.open()
        await request.applicationFinished.wait()
        let open = try await client.sessions.openSession(id: first.id)
        #expect(open.timeListening == (applied ? 3 : 0))
        #expect(open.currentTime == (applied ? 10 : 0))
        #expect(try await client.sessions.listeningSessions(itemID: "a").total == (applied ? 1 : 0))
        #expect(
            try await client.progress.fetchProgress(itemID: "a", episodeID: nil)?.currentTime == (applied ? 10 : nil))
        request.respond.open()
        await #expect(throws: applied ? ReconciliationSessionModel.Failure.responseLost : .notApplied) {
            try await sync.value
        }
    }

    @Test(arguments: [true, false])
    func closeApplicationRetainsTotalsDespiteAmbiguousResponse(applied: Bool) async throws {
        let model = ReconciliationSessionModel()
        let client = Adapters(model)
        let first = try await client.start()
        try await client.progress.syncSession(id: first.id, report: client.report(20, 2))
        let request = ReconciliationSessionModel.Request(applied ? .appliedResponseLost : .unapplied)
        defer { request.release() }
        await model.enqueue(request, for: .close)
        let close = Task { try await client.sessions.closeSession(id: first.id, report: client.report(5, 3)) }
        await request.arrived.wait()
        #expect(try await client.sessions.openSession(id: first.id).currentTime == 20)
        request.enter.open()
        await request.entered.wait()
        #expect(try await client.sessions.openSession(id: first.id).timeListening == 2)
        request.apply.open()
        await request.applicationFinished.wait()
        if applied {
            await #expect(throws: APIError.notFound) { try await client.sessions.openSession(id: first.id) }
        } else {
            #expect(try await client.sessions.openSession(id: first.id).timeListening == 2)
        }
        let stored = try #require(try await client.sessions.listeningSessions(itemID: "a").sessions.first)
        #expect(stored.timeListening == (applied ? 5 : 2) && stored.currentTime == (applied ? 5 : 20))
        #expect(try await client.progress.fetchProgress(itemID: "a", episodeID: nil)?.currentTime == (applied ? 5 : 20))
        request.respond.open()
        await #expect(throws: applied ? ReconciliationSessionModel.Failure.responseLost : .notApplied) {
            try await close.value
        }
    }

    @Test func staleReportsAndCloseOverwriteCanonicalPositionWithoutErasingListenedTime() async throws {
        let model = ReconciliationSessionModel()
        let phone = Adapters(model)
        let watch = Adapters(model, device: "watch")
        let first = try await phone.start()
        let second = try await watch.start()
        try await phone.progress.syncSession(id: first.id, report: phone.report(20, 2))
        try await watch.progress.syncSession(id: second.id, report: watch.report(30, 7))
        try await phone.progress.syncSession(id: first.id, report: phone.report(5, 3))
        #expect(try await watch.progress.fetchProgress(itemID: "a", episodeID: nil)?.currentTime == 5)
        try await phone.sessions.closeSession(id: first.id, report: phone.report(4, 1))
        #expect(try await watch.sessions.mediaProgress(itemID: "a", episodeID: nil)?.currentTime == 4)
        #expect(try await watch.sessions.openSession(id: second.id).timeListening == 7)
        let stored = try #require(
            try await phone.sessions.listeningSessions(itemID: "a").sessions.first { $0.id == first.id })
        #expect(stored.timeListening == 6 && stored.currentTime == 4)
    }

    @Test func firstPageAbsenceDoesNotDisproveAppliedListening() async throws {
        let clock = TestClock()
        let model = ReconciliationSessionModel(clock: clock)
        let client = Adapters(model)
        var ids: [String] = []
        for index in 0..<12 {
            clock.advance(by: 1)
            let session = try await client.start()
            ids.append(session.id)
            try await client.progress.syncSession(id: session.id, report: client.report(Double(index + 1), 2))
            try await client.sessions.closeSession(id: session.id, report: nil)
        }
        let first = try await client.sessions.listeningSessions(itemID: "a")
        let later = try await client.sessions.listeningSessions(itemID: "a", page: 1)
        #expect(first.total == 12 && first.numPages == 2 && first.page == 0 && first.itemsPerPage == 10)
        #expect(first.sessions.count == 10 && !first.sessions.contains { $0.id == ids[0] })
        #expect(later.total == 12 && later.numPages == 2 && later.page == 1 && later.itemsPerPage == 10)
        #expect(later.sessions.map(\.id) == [ids[1], ids[0]])
        #expect(later.sessions.last?.timeListening == 2 && later.sessions.last?.currentTime == 1)
        #expect(Set((first.sessions + later.sessions).map(\.id)) == Set(ids))
        let smaller = try await client.sessions.listeningSessions(itemID: "a", page: 2, itemsPerPage: 5)
        #expect(smaller.total == 12 && smaller.numPages == 3 && smaller.page == 2 && smaller.itemsPerPage == 5)
        #expect(smaller.sessions == later.sessions)
        let beyond = try await client.sessions.listeningSessions(itemID: "a", page: 2)
        #expect(beyond.sessions.isEmpty && beyond.total == 12 && beyond.numPages == 2)
        #expect(try await client.sessions.listeningSessions(itemID: "b").total == 0)
    }

    @Test func zeroListeningCanApplyPositionWithoutAnyStoredRecord() async throws {
        let model = ReconciliationSessionModel()
        let client = Adapters(model)
        let first = try await client.start("podcast", episode: "one")
        try await client.progress.syncSession(id: first.id, report: client.report(8, 0))
        #expect(try await client.sessions.openSession(id: first.id).currentTime == 8)
        let second = try await client.start("podcast", episode: "two")
        try await client.sessions.closeSession(id: second.id, report: client.report(9, 0))
        for (episode, position) in [("one", 8.0), ("two", 9.0)] {
            let page = try await client.sessions.listeningSessions(itemID: "podcast", episodeID: episode)
            #expect(page.sessions.isEmpty && page.total == 0 && page.numPages == 0)
            #expect(page.page == 0 && page.itemsPerPage == 10)
            #expect(
                try await client.progress.fetchProgress(itemID: "podcast", episodeID: episode)?.currentTime == position)
        }
        #expect(try await client.progress.fetchProgress(itemID: "podcast", episodeID: nil) == nil)
    }

    @Test func storedReadSnapshotsAtApplicationNotAtEntryOrResponse() async throws {
        let model = ReconciliationSessionModel()
        let client = Adapters(model)
        let first = try await client.start()
        let request = ReconciliationSessionModel.Request()
        defer { request.release() }
        await model.enqueue(request, for: .records)
        let read = Task { try await client.sessions.listeningSessions(itemID: "a") }
        await request.arrived.wait()
        request.enter.open()
        await request.entered.wait()
        try await client.progress.syncSession(id: first.id, report: client.report(10, 2))
        request.apply.open()
        await request.applicationFinished.wait()
        try await client.progress.syncSession(id: first.id, report: client.report(20, 3))
        request.respond.open()
        let snapshot = try await read.value
        #expect(snapshot.total == 1 && snapshot.sessions.first?.timeListening == 2)
        #expect(snapshot.sessions.first?.currentTime == 10)
        let live = try await client.sessions.openSession(id: first.id)
        #expect(live.timeListening == 5 && live.currentTime == 20)
    }

    @Test func coordinatorAndSyncerUseTheSameSessionLedger() async throws {
        let s = try SyncHarness()
        let model = ReconciliationSessionModel(clock: s.h.clock)
        let client = SessionModelClient(model: model)
        s.h.service.state.withLock { $0.sessionClient = client }
        s.service.state.withLock { $0.sessionClient = client }
        await s.coordinator.play(itemID: "a")
        let id = try #require(s.coordinator.session?.id)
        await s.play(for: 15, rate: 2)
        let open = try await s.h.service.openSession(id: id)
        #expect(open.timeListening == 15 && open.currentTime == 30)
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == 30)
        #expect(try await s.service.fetchProgress(itemID: "a", episodeID: nil)?.currentTime == 30)
        let close = ReconciliationSessionModel.Request()
        defer { close.release() }
        await model.enqueue(close, for: .close)
        s.coordinator.stop()
        await close.arrived.wait()
        close.enter.open()
        await close.entered.wait()
        #expect(try await s.h.service.openSession(id: id).timeListening == 15)
        close.apply.open()
        await close.applicationFinished.wait()
        await #expect(throws: APIError.notFound) { try await s.h.service.openSession(id: id) }
        close.respond.open()
        await s.coordinator.waitForPendingCloses()
        await s.settle()
        await #expect(throws: APIError.notFound) { try await s.h.service.openSession(id: id) }
        let stored = try #require(try await s.h.service.listeningSessions(itemID: "a").sessions.first)
        #expect(stored.id == id && stored.timeListening == 15 && stored.currentTime == 30)
    }

    /// `isFinished: false` changes nothing on unfinished progress, `lastUpdate` included
    /// (`ProgressContractTests.lastUpdate`). It still creates absent progress, and on finished
    /// progress it resets the position (`finishedGroup`).
    @Test func unfinishingChangesOnlyFinishedProgress() async throws {
        let clock = TestClock()
        let client = Adapters(ReconciliationSessionModel(clock: clock))
        try await client.patch(.audio(currentTime: 12, duration: 50, progress: 0.24))
        let unfinished = try await client.row()
        clock.advance(by: 1)
        try await client.patch(.finished(false))
        #expect(try await client.row() == unfinished)

        try await client.patch(.finished(false), "b")
        let created = try await client.row("b")
        #expect(!created.isFinished && created.currentTime == 0)
        #expect(created.lastUpdate == Int(clock.now.timeIntervalSince1970 * 1000))

        try await client.patch(.finished(true))
        clock.advance(by: 1)
        try await client.patch(.finished(false))
        let reset = try await client.row()
        #expect(!reset.isFinished && reset.finishedAt == nil && reset.currentTime == 0 && reset.progress == 0)
        #expect(reset.lastUpdate == Int(clock.now.timeIntervalSince1970 * 1000))
    }

    /// A PATCH that changes nothing leaves the progress alone, `lastUpdate` included
    /// (`ProgressContractTests.lastUpdate`, `MediaProgress.applyProgressUpdate`): a repeated
    /// audio position, or an undated `isFinished: true` on finished progress, which keeps its
    /// `finishedAt`. A sent date still replaces `finishedAt` and dates the progress.
    @Test func onlyAnEffectivePatchDatesProgress() async throws {
        let clock = TestClock()
        let client = Adapters(ReconciliationSessionModel(clock: clock))
        let now = { Int(clock.now.timeIntervalSince1970 * 1000) }
        try await client.patch(.audio(currentTime: 12, duration: 50, progress: 0.24))
        let audio = try await client.row()
        clock.advance(by: 1)
        try await client.patch(.audio(currentTime: 12, duration: 50, progress: 0.24))
        #expect(try await client.row() == audio)

        try await client.patch(.finished(true))
        let finished = try await client.row()
        #expect(finished.finishedAt == now() && finished.lastUpdate == now())
        clock.advance(by: 1)
        try await client.patch(.finished(true))
        #expect(try await client.row() == finished)

        let when = clock.ago(86_400)
        try await client.patch(.finished(true, at: when))
        let dated = try await client.row()
        #expect(dated.finishedAt == Int((when.timeIntervalSince1970 * 1000).rounded()))
        #expect(dated.isFinished && dated.lastUpdate == now())
    }

    /// An audio PATCH that moves finished progress away from the end un-finishes it
    /// (`ProgressContractTests.audioUnfinishes`); exactly 10 s from the end is still away. The
    /// same position, or one fewer than 10 s from the end, leaves it finished (`MediaProgressUpdate`).
    @Test(arguments: [(20.0, false), (40, false), (10, true), (45, true)])
    func movingFinishedProgressAwayFromTheEndUnfinishesIt(to time: Double, staysFinished: Bool) async throws {
        let client = Adapters(ReconciliationSessionModel())
        try await client.patch(.audio(currentTime: 10, duration: 50, progress: 0.2))
        try await client.patch(.finished(true))
        let finished = try await client.row()
        try await client.patch(.audio(currentTime: time, duration: 50, progress: time / 50))
        let row = try await client.row()
        #expect(row.isFinished == staysFinished)
        #expect(row.finishedAt == (staysFinished ? finished.finishedAt : nil))
        #expect(row.currentTime == time)
        if !staysFinished { #expect(row.progress == time / 50) }
    }
}
