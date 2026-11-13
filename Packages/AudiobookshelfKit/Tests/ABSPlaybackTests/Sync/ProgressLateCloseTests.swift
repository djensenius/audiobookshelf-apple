import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// A request from a session this device has moved on from can't regress its newer session of the
/// same media: the next `/play` retires every open session of this user and device, so a late
/// `/sync` or `/close` for one that the server looks up after the takeover answers 404 instead of
/// writing (ADR 0007 decision 8). The model looks up and writes atomically, so it doesn't cover a
/// request whose lookup passed before the takeover and that writes after it. Another device's
/// sessions aren't retired, which leaves the cross-device race below. The close wait elapses at
/// once here; reports go out every 15 s.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProgressLateCloseTests {
    typealias Request = ReconciliationSessionModel.Request

    /// A harness whose session and progress services share one session model.
    private static func modelHarness() throws -> (SyncHarness, ReconciliationSessionModel, SessionModelClient) {
        let s = try SyncHarness()
        let model = ReconciliationSessionModel(clock: s.h.clock)
        let client = SessionModelClient(model: model)
        s.h.service.state.withLock { $0.sessionClient = client }
        s.service.state.withLock { $0.sessionClient = client }
        s.h.sleep.elapsesImmediately = true
        return (s, model, client)
    }

    private static func serverTime(_ model: ReconciliationSessionModel, _ client: SessionModelClient) async throws
        -> Double?
    {
        try await model.fetchProgress(client, itemID: "a", episodeID: nil)?.currentTime
    }

    /// Stops session 1 with its `/close` held inside the server, then starts session 2 of the same
    /// item, which retires session 1, and plays it to a later position.
    private static func takeOver(
        _ s: SyncHarness, _ model: ReconciliationSessionModel, heldClose close: Request
    ) async throws {
        close.enter.open()
        await model.enqueue(close, for: .close)
        s.coordinator.stop()
        await close.entered.wait()
        await s.coordinator.play(itemID: "a")
        #expect(s.coordinator.session?.id == "session-2")
        await s.play(for: 15, rate: 2)
    }

    /// Session 1's report times out while the server still holds it. Held before its application
    /// and released after session 2 took over, it answers 404. Applied before the takeover with
    /// its response held until after, it only moved progress to where session 2 started from and
    /// then passed, and losing its response resends nothing. Either way session 2's position stands.
    @Test(arguments: [Request.Outcome.acknowledged, .appliedResponseLost])
    func aHeldReportCannotRegressTheNextSession(outcome: Request.Outcome) async throws {
        let (s, model, client) = try Self.modelHarness()
        let applied = outcome == .appliedResponseLost
        let late = Request(outcome)
        defer { late.release() }
        late.enter.open()
        let close = Request()
        defer { close.release() }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15)
        await model.enqueue(late, for: .sync)
        s.service.state.withLock { $0.abandonedSyncs = [late] }
        await s.play(for: 15)
        #expect(s.service.log.contains("sync 2 timed out"))
        if applied {
            late.apply.open()
            await late.applicationFinished.wait()
        }
        #expect(try await model.lookup(client, id: "session-1").timeListening == (applied ? 30 : 15))
        #expect(try await Self.serverTime(model, client) == (applied ? 30 : 15))

        try await Self.takeOver(s, model, heldClose: close)
        let newer = try #require(try await Self.serverTime(model, client))
        #expect(newer > 30)

        late.apply.open()
        late.respond.open()
        await late.completed.wait()

        #expect(try await Self.serverTime(model, client) == newer)
        await #expect(throws: APIError.notFound) { try await model.lookup(client, id: "session-1") }
        close.release()
        await s.coordinator.waitForPendingCloses()
        await s.settle()
        #expect(try await Self.serverTime(model, client) == newer)
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == newer)
    }

    /// Session 1's `/close` outlives the close wait, so `/play` starts session 2 without it; once
    /// released, the server has retired session 1 and the close changes nothing. Its 404 means
    /// nothing applied, so its 5 s ride along in session 2's next report (ADR 0007).
    @Test func aLateCloseIsRetiredByTheNextPlay() async throws {
        let (s, model, client) = try Self.modelHarness()
        let close = Request()
        defer { close.release() }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 20)
        try await Self.takeOver(s, model, heldClose: close)
        let newer = try #require(try await Self.serverTime(model, client))
        #expect(newer > 20)

        close.release()
        await close.completed.wait()
        await s.coordinator.waitForPendingCloses()
        await s.settle()

        #expect(s.h.service.closes == ["session-1"])
        #expect(try await Self.serverTime(model, client) == newer)
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == newer)
        // The takeover saved session 1's listening; the late close added nothing to it.
        var stored = try await s.h.service.listeningSessions(itemID: "a").sessions
        #expect(stored.first { $0.id == "session-1" }?.timeListening == 15)
        #expect(s.syncer.closeQueue.carried.isEmpty)

        // Session 2 played 15 s; its close reports them with session 1's last 5 s, once.
        s.coordinator.stop()
        await s.coordinator.waitForPendingCloses()
        await s.settle()
        await s.syncer.closeQueue.waitForCaptures()
        stored = try await s.h.service.listeningSessions(itemID: "a").sessions
        #expect(stored.first { $0.id == "session-1" }?.timeListening == 15)
        #expect(stored.first { $0.id == "session-2" }?.timeListening == 20)
        #expect(!s.service.log.contains("records a"))
    }

    /// A `/close` goes out from the coordinator once per session. The syncer resends one the
    /// server may not have applied once, after the reconcile delay and through the admission rule
    /// (#382), and its listening time counts once: never applied, the resend is acknowledged;
    /// applied with its response lost, the resend meets the closed session's 404, and the
    /// session's stored record shows it counted, so it's dropped. One answered 404 after a server
    /// restart is never resent: nothing applied, so its 5 s ride along in session 2 (ADR 0007).
    @Test(arguments: [nil, Request.Outcome.unapplied, .appliedResponseLost])
    func aCloseIsResentOnlyWhileItCanStillCount(outcome: Request.Outcome?) async throws {
        let (s, model, _) = try Self.modelHarness()
        await s.coordinator.play(itemID: "a")
        await s.play(for: 20)
        if let outcome {
            let failing = Request(outcome)
            failing.release()
            await model.enqueue(failing, for: .close)
        } else {
            await model.restart()
        }
        s.coordinator.stop()
        await s.coordinator.waitForPendingCloses()
        await s.settle()
        await s.syncer.closeQueue.waitForCaptures()

        // Every later chance to resend: drains past the retry delay, the next session, its
        // reports and its close.
        s.h.clock.advance(by: s.syncer.reconcileDelay)
        await s.syncer.drainPendingProgress()
        await s.coordinator.play(itemID: "a")
        await s.play(for: 20)
        s.coordinator.stop()
        await s.coordinator.waitForPendingCloses()
        await s.settle()
        await s.syncer.closeQueue.waitForCaptures()
        s.h.clock.advance(by: s.syncer.reconcileDelay)
        await s.syncer.drainPendingProgress()

        #expect(s.h.service.closes == ["session-1", "session-2"])
        #expect(s.service.closes.map(\.id) == (outcome == nil ? [] : ["session-1"]))
        let stored = try await s.h.service.listeningSessions(itemID: "a").sessions
        #expect(stored.first { $0.id == "session-1" }?.timeListening == (outcome == nil ? 15 : 20))
        #expect(stored.first { $0.id == "session-2" }?.timeListening == (outcome == nil ? 25 : 20))
        // Every second played counts once.
        #expect(stored.map(\.timeListening).reduce(0, +) == 40)
        #expect(s.service.log.contains("records a") == (outcome == .appliedResponseLost))
        #expect(try await s.store.sessionCloses(for: s.h.connectionID).isEmpty)
        #expect(s.syncer.closeQueue.carried.isEmpty)
    }

    /// Characterization of a documented limit: the tablet's sessions aren't retired by the phone's
    /// `/play`, nor the phone's by the tablet's, so a slow phone `/close` that the server applies
    /// after the tablet's newer report sets the position back. Landing first, it's overwritten.
    @Test(arguments: [false, true])
    func aSlowCloseCanOverwriteAnotherDevice(closeLandsFirst: Bool) async throws {
        let (s, model, client) = try Self.modelHarness()
        let close = Request()
        defer { close.release() }
        close.enter.open()
        await s.coordinator.play(itemID: "a")
        await s.play(for: 20)
        await model.enqueue(close, for: .close)
        s.coordinator.stop()
        await close.entered.wait()
        if closeLandsFirst {
            close.apply.open()
            await close.applicationFinished.wait()
        }

        let tablet = SessionModelClient(model: model, deviceID: "tablet")
        let session = try await model.start(tablet, itemID: "a", episodeID: nil)
        try await model.sync(
            tablet, id: session.id,
            report: #require(PlaybackSyncReport(currentTime: 900, timeListened: 30, duration: 3600)))
        close.release()
        await s.coordinator.waitForPendingCloses()
        await s.settle()

        #expect(try await Self.serverTime(model, client) == (closeLandsFirst ? 900 : 20))
        #expect(try await model.lookup(tablet, id: session.id).currentTime == 900)
    }
}
