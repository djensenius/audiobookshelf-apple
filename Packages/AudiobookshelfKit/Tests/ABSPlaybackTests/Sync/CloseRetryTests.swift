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
    /// The verdicts the syncer's close passes gave, in order.
    let given = Box<[(sessionID: String, verdict: DeferredReportAdmission)]>([])

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
        s.syncer.closeQueue.verdictGiven = { [given] in given.value.append(($0, $1)) }
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
    func listened(_ sessionID: String, itemID: String = "a") async throws -> Double? {
        try await model.records(client, itemID: itemID, episodeID: nil).sessions.first { $0.id == sessionID }?
            .timeListening
    }

    /// The stub server's progress for "a", merged into the row as a fetch is; returns it.
    @discardableResult
    func mergeServerProgress() async throws -> MediaProgress {
        let progress = try #require(try await model.fetchProgress(client, itemID: "a", episodeID: nil))
        let server = ProgressBaseline(
            currentTime: progress.currentTime, progress: progress.progress, duration: progress.duration,
            isFinished: progress.isFinished,
            finishedAt: progress.finishedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
            ebookLocation: progress.ebookLocation, ebookProgress: progress.ebookProgress,
            lastUpdate: Date(timeIntervalSince1970: Double(try #require(progress.lastUpdate)) / 1000))
        let capture = await s.store.captureProgressFetch(for: key)
        try await s.store.applyServerProgress([key: server], capturedAt: capture.generation, source: .fetch)
        return progress
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

    var verdicts: [DeferredReportAdmission] { given.value.map(\.verdict) }
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
    /// close is never resent, and the server keeps the newer session's position. Its stored
    /// record, at what was acknowledged, shows it never counted, so the newer session takes its
    /// 5 s for its next report (#383). Another item's session doesn't hold it back: its resend
    /// then meets the retired session's 404, and the same record says the same, so its 5 s wait
    /// for the media's next session.
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
        #expect(f.s.service.log.filter { $0 == "records a" }.count == 1)
        #expect(f.s.syncer.closeQueue.carried.map(\.seconds) == (sameItem ? [] : [5]))
        #expect(try await f.listened("session-1") == 15)
    }

    /// The item is marked finished while session 1's close waits to be resent. A resend carries
    /// the old position, which un-finishes the item on the server unless the row's position
    /// PATCH and its finished PATCH reached the server first. So a pass whose PATCH for the row
    /// fails leaves the close for the next drain, which sends both PATCHes before it. The close
    /// then repeats the server's position, so the item stays finished there and locally.
    @Test(arguments: [false, true])
    func aResendWaitsForItsRowsPatches(patchFails: Bool) async throws {
        let f = try CloseRetryFixture()
        try await f.stopSessionOne(.unapplied)
        #expect(try await f.serverTime() == 15)
        try await f.model.update(f.client, itemID: "a", episodeID: nil, .finished(true))
        // The action's local hook runs once the server accepted it.
        try await f.s.store.recordEdit(ProgressEdit(isFinished: true), for: f.key, now: f.s.h.clock.now + 1)
        if patchFails { f.s.service.state.withLock { $0.patchErrors = [.http(status: 500, message: nil)] } }

        await f.drainWhenDue()

        let server = try #require(try await f.model.fetchProgress(f.client, itemID: "a", episodeID: nil))
        if patchFails {
            #expect(f.s.service.closes.isEmpty)
            #expect(server.isFinished && server.currentTime == 15)
            #expect(try await f.queued().map(\.sessionID) == ["session-1"])
            await f.drainWhenDue()
        }
        #expect(f.s.service.closes.map(\.id) == ["session-1"])
        let log = f.s.service.log.filter { $0 == "patch a" || $0 == "close session-1" }
        #expect(log.suffix(3) == ["patch a", "patch a", "close session-1"])
        let patches = f.s.service.patches.suffix(2).map(\.update)
        #expect(patches.map(\.currentTime) == [20, nil] && patches.map(\.isFinished) == [nil, true])
        #expect(try await f.queued().isEmpty)
        let closed = try await f.mergeServerProgress()
        #expect(closed.isFinished && closed.currentTime == 20)
        #expect(try await f.s.store.progress(for: f.key)?.isFinished == true)
    }

    /// A send for the row still in flight on the shared writer (a retiring scope's) while another
    /// syncer drains: that drain can't send the row's edits, so it holds the close too, and sends
    /// it once they reached the server.
    @Test func aResendWaitsForASendInFlightOnTheSharedWriter() async throws {
        let f = try CloseRetryFixture()
        try await f.stopSessionOne(.unapplied)
        try await f.model.update(f.client, itemID: "a", episodeID: nil, .finished(true))
        try await f.s.store.recordEdit(ProgressEdit(isFinished: true), for: f.key, now: f.s.h.clock.now + 1)
        let attempt = try #require(try await f.queued().first?.lastAttemptAt)
        let patch = Gate()
        let patchStarted = Gate()
        f.s.service.state.withLock {
            $0.patchGates = [patch]
            $0.patchStarted = patchStarted
        }
        // The retiring scope's drain: its close isn't due, and its first PATCH is held.
        let retiring = Task { await f.s.syncer.drainPendingProgress() }
        await patchStarted.wait()

        let r = try CloseRetryFixture(progressStore: f.s.store, connectionID: f.s.h.connectionID, model: f.model)
        r.s.h.clock.advance(by: attempt.timeIntervalSince(r.s.h.clock.now) + r.s.syncer.reconcileDelay)
        await r.s.syncer.drainPendingProgress()
        #expect(r.s.service.patches.isEmpty)
        #expect(r.s.service.closes.isEmpty)
        #expect(try await f.model.fetchProgress(f.client, itemID: "a", episodeID: nil)?.isFinished == true)

        patch.open()
        await retiring.value
        #expect(f.s.service.patches.suffix(2).map(\.update.isFinished) == [nil, true])
        await r.s.syncer.drainPendingProgress()
        #expect(r.s.service.closes.map(\.id) == ["session-1"])
        let closed = try await f.mergeServerProgress()
        #expect(closed.isFinished && closed.currentTime == 20)
        #expect(try await f.s.store.progress(for: f.key)?.isFinished == true)
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
        // The pass ended early, or not: its record of captures ended with it.
        #expect(f.s.syncer.closeQueue.passCaptures == nil)
    }

    /// Saving the attempt suspends, so admission's checks run again before the resend: an
    /// account that ended meanwhile keeps the close, and a newer session of the same media
    /// settles it unsent. Marking the item not finished or discarding its progress changes the
    /// row in the store without queuing a position: the close is kept unsent, and the next drain
    /// finds its position gone and settles it, still unsent: its stored record carries its 5 s
    /// (#383).
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
        #expect(f.s.syncer.closeQueue.passCaptures == nil)
        guard itemAction else { return }

        f.s.syncer.closeQueue.reached = nil
        await f.drainWhenDue()

        #expect(f.verdicts == [.skip(.lookupFailed), .skip(.positionSuperseded)])
        #expect(f.s.service.closes.isEmpty)
        #expect(try await f.queued().isEmpty)
        #expect(try await f.s.store.progress(for: f.key)?.currentTime == (change == "discard" ? nil : 0))
        #expect(try await f.listened("session-1") == 15)
        #expect(f.s.syncer.closeQueue.carried.map(\.seconds) == [5])
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

    /// A close being captured when a drain reads the queue, its capture begun before the pass or
    /// as the pass starts, is left alone for the whole pass: its `/close` may settle while the
    /// pass is suspended on an older close, leaving the copy the pass read stale. Acknowledged
    /// meanwhile, the close isn't recreated or resent; kept, it isn't resent before its new retry
    /// delay, and then goes out once. The pass's record of captures ends with the pass.
    @Test(arguments: [CloseRetryFixture.Request.Outcome.acknowledged, .unapplied], [false, true])
    func aCloseSettlingDuringAPassIsLeftToTheNextDrain(
        outcome: CloseRetryFixture.Request.Outcome, capturedAsThePassStarts: Bool
    ) async throws {
        let f = try CloseRetryFixture()
        try await f.stopSessionOne(.unapplied)
        await f.s.coordinator.play(itemID: "b")
        await f.s.play(for: 20)
        await f.s.settle()
        let close = CloseRetryFixture.Request(outcome)
        defer { close.release() }
        await f.model.enqueue(close, for: .close)
        let queue = f.s.syncer.closeQueue
        let stored = Gate()
        queue.reached = { step in
            switch step {
            case .captureSaved:
                stored.open()
            case .passStarted where capturedAsThePassStarts:
                // Session 2 stops once the pass noted the sessions being captured, so its close is
                // stored in flight before the pass reads the queue.
                f.s.coordinator.stop()
                await stored.wait()
            case .attemptSaved:
                // The pass takes session 1 first. Session 2's `/close` settles a reconcile delay
                // later, so the copy the pass read is due by then.
                queue.reached = nil
                f.s.h.clock.advance(by: f.s.syncer.reconcileDelay)
                close.release()
                await f.s.coordinator.waitForPendingCloses()
                await queue.waitForCaptures()
            default:
                break
            }
        }
        if !capturedAsThePassStarts {
            f.s.coordinator.stop()
            await stored.wait()
            await f.s.settle()
            #expect(try await f.queued().map(\.sessionID) == ["session-1", "session-2"])
        }
        #expect(queue.passCaptures == nil)

        await f.drainWhenDue()

        #expect(queue.passCaptures == nil)
        #expect(f.s.service.closes.map(\.id) == ["session-1"])
        #expect(f.given.value.map(\.sessionID) == ["session-1"])
        let kept = try await f.queued()
        if outcome == .acknowledged {
            #expect(kept.isEmpty)
            #expect(f.s.syncer.drainWake == nil)
        } else {
            #expect(kept.map(\.sessionID) == ["session-2"])
            #expect(kept.first?.attempts == 1 && kept.first?.lastAttemptAt == f.s.h.clock.now)
            #expect(f.s.syncer.drainWake != nil)
        }
        #expect(try await f.listened("session-2", itemID: "b") == (outcome == .acknowledged ? 20 : 15))

        await f.drainWhenDue()

        #expect(
            f.s.service.closes.map(\.id) == (outcome == .acknowledged ? ["session-1"] : ["session-1", "session-2"]))
        #expect(try await f.queued().isEmpty)
        #expect(try await f.listened("session-2", itemID: "b") == 20)
    }

    /// A retired playback scope's capture goes on after its syncer detaches, unseen by the
    /// replacement scope's ``CloseRetryQueue``, which shares the store: the replacement's pass
    /// reads that close in flight. If it settles while the pass is suspended on an older close,
    /// the pass's attempt claim finds the stored close changed. Acknowledged meanwhile, it isn't
    /// recreated or resent; kept, it isn't resent before the delay its settlement saved, and the
    /// next drain resends it once.
    @Test(arguments: [CloseRetryFixture.Request.Outcome.acknowledged, .unapplied])
    func aReplacementScopeLeavesARetiredScopesSettledCloseAlone(
        outcome: CloseRetryFixture.Request.Outcome
    ) async throws {
        let f = try CloseRetryFixture()
        try await f.stopSessionOne(.unapplied)
        await f.s.coordinator.play(itemID: "b")
        await f.s.play(for: 20)
        let close = CloseRetryFixture.Request(outcome)
        defer { close.release() }
        await f.model.enqueue(close, for: .close)
        let stored = Gate()
        f.s.syncer.closeQueue.reached = { if $0 == .captureSaved { stored.open() } }
        f.s.coordinator.stop()
        await stored.wait()
        await f.s.settle()
        // The account switches away, the scope retiring with session 2's `/close` out, and back:
        // a new scope over the same store and connection, its clock where the old one's is.
        f.s.syncer.detach()
        let r = try CloseRetryFixture(progressStore: f.s.store, connectionID: f.s.h.connectionID, model: f.model)
        r.s.h.clock.advance(by: f.s.h.clock.now.timeIntervalSince(r.s.h.clock.now))
        #expect(try await r.queued().map(\.sessionID) == ["session-1", "session-2"])
        let queue = r.s.syncer.closeQueue
        queue.reached = { step in
            // The pass takes session 1 first; session 2's `/close` settles once its attempt is saved.
            guard step == .attemptSaved else { return }
            queue.reached = nil
            f.s.h.clock.advance(by: r.s.h.clock.now.timeIntervalSince(f.s.h.clock.now))
            close.release()
            await f.s.coordinator.waitForPendingCloses()
            await f.s.syncer.closeQueue.waitForCaptures()
        }

        // Both closes are due.
        await r.drainWhenDue()

        #expect(r.s.service.closes.map(\.id) == ["session-1"])
        #expect(r.given.value.map(\.sessionID) == ["session-1", "session-2"])
        #expect(r.verdicts == [.send, .skip(.closeChanged)])
        let kept = try await r.queued()
        if outcome == .acknowledged {
            #expect(kept.isEmpty)
        } else {
            #expect(kept.map(\.sessionID) == ["session-2"])
            #expect(kept.first?.attempts == 1 && kept.first?.lastAttemptAt == r.s.h.clock.now)
        }
        #expect(r.s.syncer.drainWake != nil)
        #expect(try await f.listened("session-2", itemID: "b") == (outcome == .acknowledged ? 20 : 15))

        await r.drainWhenDue()

        #expect(
            r.s.service.closes.map(\.id) == (outcome == .acknowledged ? ["session-1"] : ["session-1", "session-2"]))
        #expect(try await r.queued().isEmpty)
        #expect(try await f.listened("session-2", itemID: "b") == 20)
    }

    /// A coordinator `/close` that failed before the capture looked leaves the capture's
    /// settlement as the close's first save. If that save fails, the close is held in memory,
    /// kept to retry, and the next drain saves it before anything else and resends it once due:
    /// its 5 s count once. If the drain's save fails too, the close waits for the drain after.
    @Test(arguments: ["saved", "capture's save fails", "drain's save fails too"])
    func aCloseWhoseFirstSaveFailsIsSavedByADrain(failure: String) async throws {
        let f = try CloseRetryFixture()
        await f.s.coordinator.play(itemID: "a")
        await f.s.play(for: 20)
        let close = CloseRetryFixture.Request(.unapplied)
        close.release()
        await f.model.enqueue(close, for: .close)
        // The closing position commits only once the coordinator's `/close` failed, so the
        // capture finds that attempt over and doesn't save the close while it is out.
        let persistence = Gate()
        defer { persistence.open() }
        f.s.syncer.beforePositionPersistence = { await persistence.wait() }
        f.s.syncer.closeQueue.reached = { step in
            // The settlement's save is the store's next commit.
            if step == .transportSettled, failure != "saved" {
                await f.s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
            }
        }
        f.s.coordinator.stop()
        await f.s.coordinator.waitForPendingCloses()
        persistence.open()
        await f.s.syncer.closeQueue.waitForCaptures()
        f.s.syncer.closeQueue.reached = nil

        let held = f.s.syncer.closeQueue.unsaved
        #expect(held.map(\.sessionID) == (failure == "saved" ? [] : ["session-1"]))
        #expect(held.allSatisfy { $0.attempts == 1 && $0.lastAttemptAt != nil })
        #expect(try await f.queued().count == (failure == "saved" ? 1 : 0))
        #expect(f.s.syncer.drainWake != nil)
        #expect(try await f.listened("session-1") == 15)
        if failure == "drain's save fails too" {
            // Saving the held close is the drain's first commit.
            await f.s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
            await f.drainWhenDue()
            #expect(f.s.syncer.closeQueue.unsaved == held)
            #expect(f.s.service.closes.isEmpty)
            #expect(try await f.queued().isEmpty)
            #expect(f.s.syncer.drainWake != nil)
        }

        await f.drainWhenDue()

        #expect(f.s.syncer.closeQueue.unsaved.isEmpty)
        #expect(f.s.service.closes.map(\.id) == ["session-1"])
        #expect(f.verdicts == [.send])
        #expect(try await f.queued().isEmpty)
        #expect(try await f.listened("session-1") == 20)
    }

    /// At most `unsavedLimit` unsaved closes are held, the oldest dropped first, and detaching
    /// drops them all, as no drain follows.
    @Test func unsavedClosesAreBoundedAndDroppedOnDetach() throws {
        let f = try CloseRetryFixture()
        let queue = f.s.syncer.closeQueue
        let limit = CloseRetryQueue.unsavedLimit
        for index in 0...limit {
            queue.holdUnsaved(
                PendingSessionCloseDTO(
                    key: f.key, sessionID: "session-\(index)", currentTime: 20, timeListened: 5, duration: 3600,
                    positionEditedAt: nil, capturedAt: f.s.h.clock.now))
        }
        #expect(queue.unsaved.map(\.sessionID) == (1...limit).map { "session-\($0)" })

        f.s.syncer.detach()

        #expect(queue.unsaved.isEmpty)
    }
}
