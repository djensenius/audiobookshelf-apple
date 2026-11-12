import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSData
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

    /// What `LocalProgressItemActionSync` (ABSAppModel) does to "a"'s row once the server took
    /// the action: discarding its progress deletes the row, marking it not finished resets it to 0.
    func applyItemAction(discard: Bool) async {
        do {
            if discard {
                #expect(try await s.store.deleteProgress(for: key))
                return
            }
            guard let row = try await s.store.progress(for: key) else {
                Issue.record("No row to mark not finished")
                return
            }
            let audio = ProgressEdit.Audio(currentTime: 0, duration: row.duration, progress: 0)
            try await s.store.recordEdit(ProgressEdit(audio: audio, isFinished: false), for: key)
        } catch {
            Issue.record(error)
        }
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

    /// A resend's attempt time is saved before it reaches the server, as the coordinator's
    /// attempt is, so a relaunch while it is out waits for it. One that never reached the server
    /// (no connection to the host) keeps the previous attempt's time.
    @Test(arguments: [false, true])
    func aResendSavesItsAttemptBeforeSending(unreachable: Bool) async throws {
        let f = try CloseRetryFixture()
        try await f.stopSessionOne(.unapplied)
        let first = try #require(try await f.queued().first?.lastAttemptAt)
        let resend = CloseRetryFixture.Request(.acknowledged)
        defer { resend.release() }
        if unreachable {
            f.s.service.state.withLock { $0.closeErrors = [.network(.cannotConnectToHost)] }
        } else {
            await f.model.enqueue(resend, for: .close)
        }

        let drain = Task { await f.drainWhenDue() }
        if !unreachable {
            await resend.arrived.wait()
            let inFlight = try #require(try await f.queued().first)
            #expect(inFlight.lastAttemptAt == f.s.h.clock.now)
            #expect(inFlight.lastAttemptAt != first)
            #expect(inFlight.attempts == 1)
            resend.release()
        }
        await drain.value

        #expect(f.s.service.closes.map(\.id) == ["session-1"])
        let queued = try await f.queued()
        if unreachable {
            #expect(queued.first?.lastAttemptAt == first)
            #expect(queued.first?.attempts == 2)
        } else {
            #expect(queued.isEmpty)
            #expect(try await f.listened("session-1") == 20)
        }
    }

    /// A resend whose attempt time couldn't be saved isn't sent: the close stays as it was and
    /// the drain retries.
    @Test(arguments: [false, true])
    func aResendIsNotSentUnlessItsAttemptSaved(saveFails: Bool) async throws {
        let f = try CloseRetryFixture()
        try await f.stopSessionOne(.unapplied)
        let first = try #require(try await f.queued().first?.lastAttemptAt)
        if saveFails {
            f.s.syncer.closeQueue.reached = { step in
                // The attempt's save is the store's next commit.
                if step == .positionRead { await f.s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission)) }
            }
        }

        await f.drainWhenDue()

        #expect(f.s.service.closes.map(\.id) == (saveFails ? [] : ["session-1"]))
        #expect(f.verdicts == (saveFails ? [] : [.send]))
        #expect(try await f.queued().first?.lastAttemptAt == (saveFails ? first : nil))
        #expect((f.s.syncer.drainWake != nil) == saveFails)
    }

    /// Saving the attempt suspends, so admission's checks run again before the resend: an
    /// account that ended meanwhile keeps the close, and a newer session of the same media
    /// removes it. Marking the item not finished or discarding its progress changes the row in
    /// the store without queuing a position: the close is kept unsent, and the next drain finds
    /// its position gone and removes it, still unsent.
    @Test(arguments: [nil, "quiesce", "newer session", "mark not finished", "discard"])
    func aChangeWhileSavingTheAttemptSkipsTheResend(change: String?) async throws {
        let f = try CloseRetryFixture()
        try await f.stopSessionOne(.unapplied)
        let saved = Gate()
        f.s.syncer.closeQueue.reached = { step in
            guard step == .attemptSaved else { return }
            saved.open()
            switch change {
            case "quiesce": f.s.syncer.quiesceTransport()
            case "newer session": await f.s.coordinator.play(itemID: "a")
            case "mark not finished", "discard": await f.applyItemAction(discard: change == "discard")
            default: break
            }
        }

        await f.drainWhenDue()

        await saved.wait()
        let itemAction = change == "mark not finished" || change == "discard"
        switch change {
        case nil: #expect(f.verdicts == [.send])
        case "quiesce": #expect(f.verdicts == [.skip(.quiesced)])
        case "newer session": #expect(f.verdicts == [.skip(.newerSessionForMedia)])
        default: #expect(f.verdicts == [.skip(.lookupFailed)])
        }
        #expect(f.s.service.closes.map(\.id) == (change == nil ? ["session-1"] : []))
        #expect(try await f.queued().count == (change == "quiesce" || itemAction ? 1 : 0))
        guard itemAction else { return }

        f.s.syncer.closeQueue.reached = nil
        await f.drainWhenDue()

        #expect(f.verdicts == [.skip(.lookupFailed), .skip(.positionSuperseded)])
        #expect(f.s.service.closes.isEmpty)
        #expect(try await f.queued().isEmpty)
        #expect(try await f.s.store.progress(for: f.key)?.currentTime == (change == "discard" ? nil : 0))
        #expect(try await f.listened("session-1") == 15)
    }

    /// A captured close whose settlement couldn't be saved (here, removing it once the
    /// coordinator's `/close` was acknowledged) schedules a drain, like one kept to retry.
    @Test(arguments: [false, true])
    func aCaptureWhoseSettlementFailsSchedulesADrain(removalFails: Bool) async throws {
        let f = try CloseRetryFixture()
        await f.s.coordinator.play(itemID: "a")
        await f.s.play(for: 20)
        let close = CloseRetryFixture.Request(.acknowledged)
        defer { close.release() }
        await f.model.enqueue(close, for: .close)
        let stored = Gate()
        f.s.syncer.closeQueue.reached = { if $0 == .captureSaved { stored.open() } }
        f.s.coordinator.stop()
        await stored.wait()
        await f.s.settle()
        #expect(try await f.queued().count == 1)
        #expect(f.s.syncer.drainWake == nil)
        // Removing the acknowledged close is the store's next commit.
        if removalFails { await f.s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission)) }

        close.release()
        await f.s.coordinator.waitForPendingCloses()
        await f.s.syncer.closeQueue.waitForCaptures()

        #expect(try await f.listened("session-1") == 20)
        #expect(try await f.queued().count == (removalFails ? 1 : 0))
        #expect((f.s.syncer.drainWake != nil) == removalFails)
    }

    /// A captured close kept to retry, or whose settlement couldn't be saved, while a drain is
    /// refreshing the current session's progress marks that drain failed, so the drain's end keeps
    /// the retry instead of cancelling it as a completed drain does. One acknowledged meanwhile
    /// leaves the drain completed, with no retry.
    @Test(arguments: ["kept", "store failed", "acknowledged"])
    func aCaptureSettlingDuringADrainKeepsItsRetry(settlement: String) async throws {
        let f = try CloseRetryFixture()
        await f.s.coordinator.play(itemID: "a")
        await f.s.play(for: 20)
        let close = CloseRetryFixture.Request(settlement == "kept" ? .unapplied : .acknowledged)
        defer { close.release() }
        await f.model.enqueue(close, for: .close)
        let stored = Gate()
        f.s.syncer.closeQueue.reached = { if $0 == .captureSaved { stored.open() } }
        f.s.coordinator.stop()
        await stored.wait()
        // Another item loads paused, with no position to send, so the drain ends refreshing it.
        let coordinator = f.s.coordinator
        let observer = coordinator.addObserver { if case .sessionStarted = $0 { coordinator.pause() } }
        await coordinator.play(itemID: "b")
        coordinator.removeObserver(observer)
        await f.s.settle()
        let refreshing = Gate()
        f.s.syncer.beforeActiveProgressCapture = {
            refreshing.open()
            // Removing the acknowledged close is the store's next commit.
            if settlement == "store failed" {
                await f.s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
            }
            close.release()
            await f.s.coordinator.waitForPendingCloses()
            await f.s.syncer.closeQueue.waitForCaptures()
        }

        await f.s.syncer.drainPendingProgress()

        await refreshing.wait()
        #expect(try await f.queued().count == (settlement == "acknowledged" ? 0 : 1))
        #expect((f.s.syncer.drainWake != nil) == (settlement != "acknowledged"))
    }
}
