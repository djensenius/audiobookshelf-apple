import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// A coordinator and syncer sharing one session model, the stub server. Session 1 of "a" plays
/// 20 s, reported at 15 s, so its `/close` carries the last 5 s of listening at 20.
@MainActor
struct CloseRetryFixture {
    typealias Request = ReconciliationSessionModel.Request

    let s: SyncHarness
    let model: ReconciliationSessionModel
    let client: SessionModelClient

    init(
        progressStore: LocalProgressStore? = nil, connectionID: UUID = UUID(),
        model: ReconciliationSessionModel? = nil
    ) throws {
        let s = try SyncHarness(progressStore: progressStore, connectionID: connectionID)
        let model = model ?? ReconciliationSessionModel(clock: s.h.clock)
        let client = SessionModelClient(model: model)
        s.h.service.state.withLock { $0.sessionClient = client }
        s.service.state.withLock { $0.sessionClient = client }
        s.h.sleep.elapsesImmediately = true
        (self.s, self.model, self.client) = (s, model, client)
    }

    var key: MediaKey { s.h.key("a") }

    /// Plays and stops session 1, the server answering its `/close` with `outcome`, and returns
    /// once the close settled.
    func stopSessionOne(_ outcome: Request.Outcome) async throws {
        await s.coordinator.play(itemID: "a")
        await s.play(for: 20)
        let close = Request(outcome)
        close.release()
        await model.enqueue(close, for: .close)
        s.coordinator.stop()
        await s.coordinator.waitForPendingCloses()
        await s.settle()
        await s.syncer.closeQueue.waitForCaptures()
    }

    /// The closes kept to retry.
    func queued() async throws -> [PendingSessionCloseDTO] {
        try await s.store.sessionCloses(for: s.h.connectionID)
    }

    /// The stub server's position for "a".
    func serverTime() async throws -> Double? {
        try await model.fetchProgress(client, itemID: "a", episodeID: nil)?.currentTime
    }

    /// The listening time the stub server stored for a session.
    func listened(_ sessionID: String) async throws -> Double? {
        try await model.records(client, itemID: "a", episodeID: nil).sessions.first { $0.id == sessionID }?
            .timeListening
    }

    /// Moves past the close's retry delay and drains.
    func drainWhenDue() async {
        s.h.clock.advance(by: s.syncer.reconcileDelay)
        await s.syncer.drainPendingProgress()
    }

    var verdicts: [DeferredReportAdmission] { s.syncer.closeQueue.verdicts.map(\.verdict) }
}

/// #382's acceptance: a `/close` the server didn't acknowledge is kept across a relaunch and
/// resent once, through the admission rule, so it never moves the server back (#195).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CloseRetryTests {
    /// A close the server never applied survives a relaunch, isn't resent before the reconcile
    /// delay, and is then acknowledged once: its 5 s count once. An acknowledged close leaves
    /// nothing to retry.
    @Test(arguments: [CloseRetryFixture.Request.Outcome.unapplied, .acknowledged])
    func aRelaunchResendsTheCloseOnce(outcome: CloseRetryFixture.Request.Outcome) async throws {
        let f = try CloseRetryFixture()
        try await f.stopSessionOne(outcome)
        let queued = try await f.queued()
        if outcome == .unapplied {
            let close = try #require(queued.first)
            #expect(queued.count == 1)
            #expect(close.sessionID == "session-1" && close.key == f.key)
            #expect(close.currentTime == 20 && close.timeListened == 5 && close.attempts == 1)
            #expect(try await f.listened("session-1") == 15)
        } else {
            #expect(queued.isEmpty)
            #expect(try await f.listened("session-1") == 20)
        }
        f.s.syncer.detach()

        // A new process: another store and syncer over the same database, its clock restarted.
        let r = try CloseRetryFixture(
            progressStore: LocalProgressStore(modelContainer: f.s.store.modelContainer),
            connectionID: f.s.h.connectionID, model: f.model)
        if let attempt = queued.first?.lastAttemptAt {
            r.s.h.clock.advance(by: attempt.timeIntervalSince(r.s.h.clock.now))
        }
        await r.s.syncer.drainPendingProgress()
        #expect(r.s.service.closes.isEmpty)
        #expect(try await f.serverTime() == 20)

        await r.drainWhenDue()
        await r.drainWhenDue()
        #expect(r.s.service.closes.map(\.id) == (outcome == .unapplied ? ["session-1"] : []))
        if outcome == .unapplied {
            #expect(
                r.s.service.closes.first?.report == PlaybackSyncReport(currentTime: 20, timeListened: 5, duration: 3600)
            )
        }
        #expect(r.verdicts == (outcome == .unapplied ? [.send] : []))
        #expect(try await r.queued().isEmpty)
        #expect(try await f.listened("session-1") == 20)
        #expect(try await f.serverTime() == 20)
    }

    /// #195 acceptance 1: another device saved newer progress after the close failed. The drain
    /// merges it, so admission skips the resend and the server keeps the tablet's position. With
    /// no newer progress the close goes out.
    @Test(arguments: [true, false])
    func anotherDevicesNewerProgressSkipsTheResend(tabletSaves: Bool) async throws {
        let f = try CloseRetryFixture()
        try await f.stopSessionOne(.unapplied)
        if tabletSaves {
            f.s.h.clock.advance(by: 10)
            let tablet = SessionModelClient(model: f.model, deviceID: "tablet")
            let session = try await f.model.start(tablet, itemID: "a", episodeID: nil)
            try await f.model.sync(
                tablet, id: session.id,
                report: #require(PlaybackSyncReport(currentTime: 900, timeListened: 30, duration: 3600)))
        }

        await f.drainWhenDue()

        #expect(try await f.serverTime() == (tabletSaves ? 900 : 20))
        #expect(f.s.service.closes.map(\.id) == (tabletSaves ? [] : ["session-1"]))
        #expect(f.verdicts == [tabletSaves ? .skip(.positionSuperseded) : .send])
        #expect(try await f.s.store.progress(for: f.key)?.currentTime == (tabletSaves ? 900 : 20))
        #expect(try await f.queued().isEmpty)
        #expect(try await f.listened("session-1") == (tabletSaves ? 15 : 20))
    }

    /// #195 acceptance 2: once a newer session of the same media is current, the old session's
    /// close is never resent, and the server keeps the newer session's position. Another item's
    /// session doesn't hold it back (its resend then meets the retired session's 404).
    @Test(arguments: [true, false])
    func aNewerSessionOfTheSameMediaSkipsTheResend(sameItem: Bool) async throws {
        let f = try CloseRetryFixture()
        try await f.stopSessionOne(.unapplied)
        await f.s.coordinator.play(itemID: sameItem ? "a" : "b")
        #expect(f.s.coordinator.session?.id == "session-2")
        await f.s.play(for: 15, rate: 2)
        let newer = try #require(try await f.serverTime())
        #expect(newer > 20 || !sameItem)

        await f.drainWhenDue()

        #expect(f.verdicts == [sameItem ? .skip(.newerSessionForMedia) : .send])
        #expect(f.s.service.closes.map(\.id) == (sameItem ? [] : ["session-1"]))
        // Without the newer session, the drain PATCHed session 1's own position.
        #expect(try await f.serverTime() == (sameItem ? newer : 20))
        #expect(try await f.queued().isEmpty)
    }
}
