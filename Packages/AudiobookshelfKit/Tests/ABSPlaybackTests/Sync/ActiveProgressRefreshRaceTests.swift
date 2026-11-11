import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSData
@testable import ABSPlayback

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ActiveProgressRefreshRaceTests {
    @Test(arguments: ["audio", "finished", "ebook", "ack", "delete", "replace", "missingABA"])
    func heldActiveGETCannotEraseInterveningHistory(kind: String) async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        let key = s.h.key("a")
        if kind != "missingABA" {
            s.h.service.state.withLock { $0.progress["a"] = ActiveRefreshFixture.reply(s, time: 200) }
        }
        await ActiveRefreshFixture.loadPaused(s)
        // A server date later than every intervening local edit exposes late provenance capture.
        s.h.clock.advance(by: 120)
        s.service.state.withLock { $0.serverProgress[key] = ActiveRefreshFixture.reply(s) }
        var afterMutation: LocalMediaProgressDTO?
        var acknowledgement: UUID?
        try await ActiveRefreshFixture.holdingGET(s) {
            switch kind {
            case "delete", "replace", "missingABA":
                if kind == "missingABA" {
                    try await s.store.recordEdit(
                        ActiveRefreshFixture.edit(), for: key, now: s.h.clock.ago(60))
                }
                #expect(try await s.store.deleteProgress(for: key))
                if kind == "replace" {
                    try await s.store.recordEdit(
                        ActiveRefreshFixture.edit(300), for: key, now: s.h.clock.ago(60))
                }
            default:
                let edit: ProgressEdit
                switch kind {
                case "finished": edit = ProgressEdit(isFinished: true)
                case "ebook": edit = ProgressEdit(ebook: .init(location: "local-page", progress: 0.8))
                default: edit = ActiveRefreshFixture.edit(300)
                }
                try await s.store.recordEdit(edit, for: key, now: s.h.clock.ago(60))
                if kind == "ack" {
                    let patch = try #require(try await s.store.beginSend(for: key))
                    #expect(try await s.store.completeSend(patch, serverLastUpdate: nil))
                    acknowledgement = patch.token
                }
            }
            afterMutation = try await s.store.progress(for: key)
        }
        #expect(try await s.store.progress(for: key) == afterMutation)
        #expect(await s.store.captureProgressFetch(for: key).acknowledgement == acknowledgement)
        #expect(s.service.state.withLock { $0.fetches } == [key])
        ActiveRefreshFixture.expectNoWrites(s)
        if kind == "ack" {
            s.service.state.withLock { $0.serverProgress[key] = ActiveRefreshFixture.reply(s, time: 300) }
            await s.syncer.drainPendingProgress()
            #expect(s.service.state.withLock { $0.fetches } == [key, key], "Confirmation, not a third active GET")
            #expect(await s.store.needsConfirmationFetch.isEmpty)
            #expect(try await s.store.progress(for: key)?.currentTime == 300)
            ActiveRefreshFixture.expectNoWrites(s)
        }
    }

    @Test(arguments: ["stop", "supersede", "detach", "quiesce", "accountSwitch", "signOut"])
    func endedOwnershipAdmitsNoHeldResponseOrContinuedRefresh(ending: String) async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        let key = s.h.key("a")
        s.h.service.state.withLock { $0.progress["a"] = ActiveRefreshFixture.reply(s, time: 300) }
        await ActiveRefreshFixture.loadPaused(s)
        let originalSession = s.coordinator.session?.id
        s.h.clock.advance(by: 60)
        s.service.state.withLock { $0.serverProgress[key] = ActiveRefreshFixture.reply(s) }
        var submissions = 0
        s.syncer.activeProgressIntakeSubmitted = { submissions += 1 }
        var beforeResponse: LocalMediaProgressDTO?
        try await ActiveRefreshFixture.holdingGET(s) {
            switch ending {
            case "detach": s.syncer.detach()
            case "quiesce": s.syncer.quiesceTransport()
            case "accountSwitch": s.coordinator.stop(reason: .accountSwitch)
            case "signOut": s.coordinator.stop(reason: .signOut)
            default:
                s.coordinator.stop()
                if ending == "supersede" {
                    // Same media key, different loaded session. Do not join the held sync drain.
                    let coordinator = s.coordinator
                    let observer = coordinator.addObserver {
                        if case .sessionStarted = $0 { coordinator.pause() }
                    }
                    await coordinator.play(itemID: "a")
                    coordinator.removeObserver(observer)
                    #expect(coordinator.session?.id != originalSession)
                    #expect(coordinator.mediaKey == key && coordinator.phase == .loaded)
                }
            }
            await s.syncer.waitForPendingWrites()
            await s.coordinator.waitForPendingCloses()
            beforeResponse = try await s.store.progress(for: key)
        }
        #expect(submissions == 0, "Invalid ownership must prevent submission, not rely on row-generation rejection")
        #expect(try await s.store.progress(for: key) == beforeResponse)
        #expect(s.service.state.withLock { $0.fetches } == [key])
        #expect(s.service.reports.isEmpty && s.service.patches.isEmpty)
        if ending == "accountSwitch" || ending == "stop" || ending == "supersede" {
            #expect(s.h.service.closes == [try #require(originalSession)])
        } else {
            #expect(s.h.service.closes.isEmpty, "Sign-out forbids close; detach/quiesce do not introduce one")
        }
        // A reusable user stop or replacement may have legitimate dirty close positions; do not
        // turn this check into a request to drain those unrelated writes.
        if ending == "detach" || ending == "quiesce" || ending == "accountSwitch" || ending == "signOut" {
            await s.syncer.drainPendingProgress()
            #expect(s.service.state.withLock { $0.fetches } == [key])
        }
    }

    @Test(arguments: ["stop", "detach", "quiesce", "accountSwitch"])
    func ownershipLostBeforeCapturePreventsFreshTransport(ending: String) async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        await ActiveRefreshFixture.loadPaused(s)
        let entered = Gate()
        let release = Gate()
        s.syncer.beforeActiveProgressCapture = {
            entered.open()
            await release.wait()
        }
        let drain = Task { await s.syncer.drainPendingProgress() }
        await entered.wait()
        switch ending {
        case "detach": s.syncer.detach()
        case "quiesce": s.syncer.quiesceTransport()
        case "accountSwitch": s.coordinator.stop(reason: .accountSwitch)
        default: s.coordinator.stop()
        }
        release.open()
        await drain.value
        await s.coordinator.waitForPendingCloses()
        #expect(s.service.state.withLock { $0.fetches.isEmpty })
        #expect(s.service.reports.isEmpty && s.service.patches.isEmpty)
    }

    @Test func noSessionOrStartingPlaceholderDoesNotRefresh() async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        await s.syncer.drainPendingProgress()
        #expect(s.service.log.isEmpty)
        let started = Gate()
        let load = Gate()
        s.h.engine.loadGates = [load]
        let observer = s.coordinator.addObserver {
            if case .sessionStarted = $0 { started.open() }
        }
        let play = Task { await s.coordinator.play(itemID: "a") }
        await started.wait()
        #expect(s.coordinator.phase == .starting)
        await s.syncer.drainPendingProgress()
        #expect(s.service.log.isEmpty)
        load.open()
        await play.value
        s.coordinator.removeObserver(observer)
        #expect(try await s.store.progress(for: s.h.key("a")) == nil)
        ActiveRefreshFixture.expectNoWrites(s)
    }

    @Test func foreignLoadedConnectionDoesNotRefreshButOwnDirtyRowsStillDrain() async throws {
        let s = try SyncHarness()
        s.syncer.detach()
        let service = StubProgressSyncService(serverConnectionID: UUID())
        let syncer = ProgressSyncer(source: s.coordinator, service: service, store: s.store)
        defer { syncer.detach() }
        await ActiveRefreshFixture.loadPaused(s)
        await syncer.drainPendingProgress()
        #expect(service.log.isEmpty)
        let own = MediaKey(serverConnectionID: service.serverConnectionID, libraryItemId: "b")
        try await s.store.recordEdit(ActiveRefreshFixture.edit(), for: own, now: s.h.clock.now)
        var response = ActiveRefreshFixture.reply(s, time: 200)
        response.libraryItemId = "b"
        service.state.withLock { $0.fetchReplies = [nil, response] }
        await syncer.drainPendingProgress()
        #expect(service.log == ["get b", "patch b", "get b"])
        #expect(try await s.store.progress(for: s.h.key("a")) == nil)
        #expect(await s.store.needsConfirmationFetch.isEmpty)
    }

    @Test func retainedSettlementFailureBlocksFreshActiveTransport() async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        await ActiveRefreshFixture.loadPaused(s)
        let dirty = s.h.key("b")
        try await s.store.recordEdit(ActiveRefreshFixture.edit(), for: dirty, now: s.h.clock.now)
        let entered = Gate()
        let response = Gate()
        s.service.state.withLock {
            $0.patchStarted = entered
            $0.patchGates = [response]
            $0.serverProgress[s.h.key("a")] = ActiveRefreshFixture.reply(s)
        }
        let drain = Task { await s.syncer.drainPendingProgress() }
        await entered.wait()
        await s.store.failNextRowFetch(with: CocoaError(.fileReadNoPermission))
        response.open()
        await drain.value
        #expect(s.service.log == ["get b", "patch b"])
        await s.store.failNextRowFetch(with: CocoaError(.fileReadNoPermission))
        await s.syncer.drainPendingProgress()
        #expect(s.service.log == ["get b", "patch b"], "Retained settlement failure blocks active GET too")
        var confirmed = ActiveRefreshFixture.reply(s, time: 200)
        confirmed.libraryItemId = "b"
        s.service.state.withLock { $0.serverProgress[dirty] = confirmed }
        await s.syncer.drainPendingProgress()
        #expect(s.service.log == ["get b", "patch b", "get b", "get a"])
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == 900)
        #expect(await s.store.needsConfirmationFetch.isEmpty)
        #expect(s.service.reports.isEmpty && s.service.patches.count == 1)
    }

    @Test func ownedPositionFailureBeforeActiveCaptureBlocksGETUntilLaterDrain() async throws {
        let s = try SyncHarness()
        defer { s.syncer.detach() }
        await ActiveRefreshFixture.loadPaused(s)
        let entered = Gate()
        let release = Gate()
        s.syncer.beforeActiveProgressCapture = {
            entered.open()
            await release.wait()
        }
        let drain = Task { await s.syncer.drainPendingProgress() }
        await entered.wait()
        await s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        s.coordinator.pause()
        await s.syncer.waitForPendingWrites()
        // The failed owned write remains pending. Both this refresh and the queued pause report
        // must defer without transport, even though the session still owns admission.
        release.open()
        await drain.value
        await s.settle()
        #expect(s.service.log.isEmpty)
        #expect(try await s.store.progress(for: s.h.key("a")) == nil)
        s.syncer.beforeActiveProgressCapture = nil
        s.service.state.withLock { $0.fetchReplies = [nil, ActiveRefreshFixture.reply(s, time: 0)] }
        await s.syncer.drainPendingProgress()
        #expect(s.service.log == ["get a", "patch a", "get a"])
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == 0)
        #expect(await s.store.needsConfirmationFetch.isEmpty)
    }
}
