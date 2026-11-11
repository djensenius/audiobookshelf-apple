import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSData
@testable import ABSPlayback

@MainActor
struct PlaybackCloseReceiptTests {
    @Test(arguments: [10.0, 100.0])
    func retiredScopeFinalWriteCannotOverwriteNewScopeCommittedSeek(target: Double) async throws {
        let old = try SyncHarness()
        await old.coordinator.play(itemID: "a", startTime: 50)
        let saving = Gate()
        let persistence = Gate()
        defer { persistence.open() }
        old.syncer.beforePositionPersistence = {
            saving.open()
            await persistence.wait()
        }
        var handoff: PlaybackCloseHandoff?
        let reporter = old.coordinator.finalCloseReport
        old.coordinator.finalCloseReport = {
            handoff = reporter?($0)
            return handoff
        }
        old.coordinator.stop(reason: .expired)
        await saving.wait()
        old.h.sleep.elapsesImmediately = true
        await #expect(throws: PlaybackCloseError.timedOut) { try await old.coordinator.waitForClose() }
        let receipt = try #require(handoff)
        old.syncer.detach()

        // A new scope for the same account shares the store, not the old syncer's serial queue.
        let newer = try SyncHarness(progressStore: old.store, connectionID: old.h.connectionID)
        newer.h.clock.advance(by: -1)  // Intent order must not depend on wall-clock order.
        await newer.coordinator.play(itemID: "a", startTime: 50)
        await newer.coordinator.seek(to: target)
        newer.syncer.quiesceTransport()
        await newer.settle()
        let committed = try #require(try await newer.store.progress(for: newer.h.key("a")))
        #expect(committed.currentTime == target)
        #expect(receipt.position.result == nil)

        persistence.open()
        try await receipt.waitForAudioPosition()
        await old.syncer.waitForPendingWrites()
        let afterOldClose = try #require(try await newer.store.progress(for: newer.h.key("a")))
        #expect(afterOldClose.currentTime == target)
        #expect(afterOldClose.audioEditedAt == committed.audioEditedAt)
        #expect(afterOldClose.lastUpdate == committed.lastUpdate)
        #expect(old.h.service.closes.isEmpty)
    }

    @Test(arguments: [10.0, 100.0])
    func reopenedExplicitStartSupersedesHeldCloseWithoutAnotherSeekOrReport(target: Double) async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a", startTime: 50)
        let saving = Gate()
        let persistence = Gate()
        defer { persistence.open() }
        s.syncer.beforePositionPersistence = {
            saving.open()
            await persistence.wait()
        }
        var handoff: PlaybackCloseHandoff?
        let reporter = s.coordinator.finalCloseReport
        s.coordinator.finalCloseReport = {
            handoff = reporter?($0)
            return handoff
        }
        s.coordinator.stop()
        await saving.wait()
        let receipt = try #require(handoff)
        await s.coordinator.waitForPendingCloses()
        s.h.clock.advance(by: -1)
        await s.coordinator.play(itemID: "a", startTime: target)
        #expect(s.coordinator.currentTime == target)
        #expect(receipt.position.result == nil)
        #expect(s.service.reports.isEmpty && s.service.patches.isEmpty)

        // No subsequent seek/pause/tick supplies a newer position: the explicit load must do it.
        persistence.open()
        try await receipt.waitForAudioPosition()
        await s.settle()
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == target)
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == true)
        #expect(s.service.reports.isEmpty && s.service.patches.isEmpty)
        s.coordinator.stop(reason: .expired)
        #expect(handoff?.report.timeListened == 0)
        _ = try await s.coordinator.waitForClose()
    }

    @Test func diskReopenKeepsNewScopesExplicitLoadAfterRetiredCloseIsReleased() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "PlaybackSupersession-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Audiobookshelf.store")
        let connectionID = UUID()
        func closeOldScopeAfterNewExplicitLoad() async throws {
            let stack = try DataStack(location: .url(url))
            let store = LocalProgressStore(modelContainer: stack.container)
            let old = try SyncHarness(progressStore: store, connectionID: connectionID)
            await old.coordinator.play(itemID: "a", startTime: 50)
            let saving = Gate()
            let persistence = Gate()
            defer { persistence.open() }
            old.syncer.beforePositionPersistence = {
                saving.open()
                await persistence.wait()
            }
            old.coordinator.stop(reason: .expired)
            await saving.wait()
            old.h.sleep.elapsesImmediately = true
            await #expect(throws: PlaybackCloseError.timedOut) { try await old.coordinator.waitForClose() }
            old.syncer.detach()

            let newer = try SyncHarness(progressStore: store, connectionID: connectionID)
            newer.h.clock.advance(by: -1)
            await newer.coordinator.play(itemID: "a", startTime: 100)  // No subsequent seek or tick.
            await newer.syncer.waitForPendingWrites()
            let committed = try #require(try await store.progress(for: newer.h.key("a")))
            #expect(committed.currentTime == 100)
            persistence.open()
            await old.syncer.waitForPendingWrites()
            #expect(try await old.coordinator.waitForClose().sessions.first?.audioPositionCommitted == true)
            #expect(try await store.progress(for: newer.h.key("a")) == committed)
            #expect(newer.service.reports.isEmpty && newer.service.patches.isEmpty)
            newer.syncer.detach()
        }
        try await closeOldScopeAfterNewExplicitLoad()
        let reopened = try DataStack(location: .url(url))
        let store = LocalProgressStore(modelContainer: reopened.container)
        let row = try #require(
            try await store.progress(for: MediaKey(serverConnectionID: connectionID, libraryItemId: "a")))
        #expect(row.currentTime == 100 && row.needsServerSync)
    }

    @Test func ordinaryCloseTransportOutlivesCoordinator() async throws {
        weak var coordinator: PlaybackCoordinator?
        func stopAndRelease() async throws -> StubSessionService {
            let h = try CoordinatorHarness()
            coordinator = h.coordinator
            await h.coordinator.play(itemID: "a")
            h.coordinator.stop()
            return h.service
        }
        let service = try await stopAndRelease()
        #expect(coordinator == nil)
        await yieldUntil { service.closes == ["a-1"] }
        #expect(service.closes == ["a-1"])
    }

    @Test(arguments: [false, true])
    func switchWaitJoinsLateOpeningCleanupWithinDeadline(resolving: Bool) async throws {
        let h = try CoordinatorHarness()
        let gate = Gate()
        defer { gate.open() }
        h.service.state.withLock {
            if resolving { $0.resolveGate = gate } else { $0.startGates["a"] = gate }
        }
        let play = Task { await h.coordinator.play(itemID: "a") }
        if resolving {
            await yieldUntil { h.service.state.withLock { $0.resolutions == 1 } }
        } else {
            await yieldUntil { h.service.starts == ["a"] }
        }
        h.coordinator.stop(reason: .accountSwitch)
        h.sleep.elapsesImmediately = true
        await #expect(throws: PlaybackCloseError.timedOut) { try await h.coordinator.waitForClose() }
        h.sleep.elapsesImmediately = false
        let waiter = Task { try await h.coordinator.waitForClose() }
        gate.open()
        await play.value
        let outcome = try await waiter.value
        #expect(outcome.sessions.map(\.sessionID) == ["a-1"])
        #expect(outcome.sessions.first?.transport == .acknowledged)
        #expect(outcome.sessions.first?.audioPositionCommitted == false)
        #expect(h.service.closes == ["a-1"])
        #expect(h.engine.loads.isEmpty)
    }

    @Test func canceledWaiterDoesNotCancelAnotherWaiterOrPositionReceipt() async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a", startTime: 50)
        let saving = Gate()
        let persistence = Gate()
        defer { persistence.open() }
        s.syncer.beforePositionPersistence = {
            saving.open()
            await persistence.wait()
        }
        s.coordinator.stop(reason: .expired)
        await saving.wait()
        var entered = false
        let canceled = Task {
            entered = true
            return try await s.coordinator.waitForClose()
        }
        let survivor = Task { try await s.coordinator.waitForClose() }
        await yieldUntil { entered }
        canceled.cancel()
        await #expect(throws: CancellationError.self) { try await canceled.value }
        #expect(try await s.store.progress(for: s.h.key("a")) == nil)
        persistence.open()
        #expect(try await survivor.value.sessions.first?.audioPositionCommitted == true)
    }

    @Test(arguments: [false, true])
    func missingAndCleanRowsRequireARealCommit(clean: Bool) async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a")
        if clean {
            await s.play(for: 15)
            #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == false)
        }
        s.h.engine.currentTime = 27
        let saving = Gate()
        let persistence = Gate()
        defer { persistence.open() }
        s.syncer.beforePositionPersistence = {
            saving.open()
            await persistence.wait()
        }
        var handoff: PlaybackCloseHandoff?
        let reporter = s.coordinator.finalCloseReport
        s.coordinator.finalCloseReport = {
            handoff = reporter?($0)
            return handoff
        }
        s.coordinator.stop(reason: .accountSwitch)
        await saving.wait()
        await s.coordinator.waitForPendingCloses()
        let receipt = try #require(handoff)
        #expect(receipt.position.result == nil)
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == (clean ? 15 : nil))
        s.h.sleep.elapsesImmediately = true
        await #expect(throws: PlaybackCloseError.timedOut) { try await s.coordinator.waitForClose() }
        #expect(s.h.sleep.durations == [.seconds(2)])
        await #expect(throws: PlaybackCloseError.timedOut) {
            try await s.coordinator.waitForClose(timeout: .milliseconds(123))
        }
        #expect(s.h.sleep.durations == [.seconds(2), .milliseconds(123)])
        #expect(receipt.position.result == nil)
        s.h.sleep.elapsesImmediately = false
        persistence.open()
        let outcome = try await s.coordinator.waitForClose()
        try await receipt.waitForAudioPosition()
        #expect(outcome.sessions.first?.transport == .acknowledged)
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == 27)
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == true)
    }

    @Test(arguments: [PlaybackStopReason.accountSwitch, .expired])
    func failedCommitIsNeverSuccessfulReceiptEvenWithTransportAck(reason: PlaybackStopReason) async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a", startTime: 50)
        // Explicit load now has its own local obligation. Fail the distinct final write,
        // not an initial write racing the failure injection.
        await s.syncer.waitForPendingWrites()
        let initial = try #require(try await s.store.progress(for: s.h.key("a")))
        #expect(initial.currentTime == 50)
        s.h.engine.currentTime = 51
        await s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        s.coordinator.stop(reason: reason)
        await s.syncer.waitForPendingWrites()
        await s.coordinator.waitForPendingCloses()
        do {
            _ = try await s.coordinator.waitForClose()
            Issue.record("A failed commit was reported as durable")
        } catch PlaybackCloseError.positionCommitFailed(let id, let description) {
            #expect(id == "a-1")
            #expect(!description.isEmpty)
        }
        #expect(try await s.store.progress(for: s.h.key("a")) == initial)
        #expect(s.h.service.closes == (reason == .accountSwitch ? ["a-1"] : []))
        // Failed data retained in memory is not a successful receipt.
        await #expect(throws: PlaybackCloseError.self) { try await s.coordinator.waitForClose() }
    }

    @Test(arguments: [PlaybackStopReason.user, .accountSwitch, .expired])
    func missingReporterIsExplicitFailure(reason: PlaybackStopReason) async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.play(itemID: "a")
        h.coordinator.stop(reason: reason)
        await #expect(throws: PlaybackCloseError.missingReporter(sessionID: "a-1")) {
            try await h.coordinator.waitForClose()
        }
        await h.coordinator.waitForPendingCloses()
    }

    @Test(arguments: [false, true])
    func failedOrUncooperativeCloseFallsBackOnlyAfterAudioCommit(hangs: Bool) async throws {
        let s = try SyncHarness()
        let gate = Gate()
        defer { gate.open() }
        s.h.service.state.withLock {
            if hangs { $0.closeGates["a-1"] = gate } else { $0.closeError = .timedOut }
        }
        await s.coordinator.play(itemID: "a", startTime: 50)
        s.coordinator.stop(reason: .accountSwitch)
        await s.syncer.waitForPendingWrites()
        await yieldUntil { s.h.service.closes == ["a-1"] }
        if hangs { s.h.sleep.elapsesImmediately = true }
        let outcome = try await s.coordinator.waitForClose()
        #expect(outcome.sessions.first?.transport == .committedAudioPositionFallback)
        #expect(outcome.sessions.first?.audioPositionCommitted == true)
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == 50)
        gate.open()
        await s.coordinator.waitForPendingCloses()
    }

    @Test func unloadedFailedTransportHasNoPositionFallback() async throws {
        let h = try CoordinatorHarness()
        let gate = Gate()
        h.engine.loadGates = [gate]
        h.service.state.withLock { $0.closeError = .timedOut }
        let play = Task { await h.coordinator.play(itemID: "a") }
        await yieldUntil { h.engine.loads.count == 1 }
        h.coordinator.stop(reason: .accountSwitch)
        gate.open()
        await play.value
        await h.coordinator.waitForPendingCloses()
        do {
            _ = try await h.coordinator.waitForClose()
            Issue.record("An unloaded session has no committed fallback")
        } catch PlaybackCloseError.transportFailed(let id, _) {
            #expect(id == "a-1")
        }
    }

    @Test func repeatedStopsAndWaitersJoinWithoutDuplicateHandoffOrClose() async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a", startTime: 50)
        let gate = Gate()
        s.h.service.state.withLock { $0.closeGates["a-1"] = gate }
        var captures = 0
        let reporter = s.coordinator.finalCloseReport
        s.coordinator.finalCloseReport = {
            captures += 1
            return reporter?($0)
        }
        s.coordinator.stop()
        await yieldUntil { s.h.service.closes == ["a-1"] }
        let first = Task { try await s.coordinator.waitForClose() }
        let second = Task { try await s.coordinator.waitForClose() }
        s.coordinator.stop(reason: .accountSwitch)
        s.coordinator.stop(reason: .accountSwitch)
        gate.open()
        #expect(try await first.value == second.value)
        #expect(try await s.coordinator.waitForClose().sessions.count == 1)
        #expect(s.h.service.closes == ["a-1"])
        #expect(captures == 1)
    }

    @Test(arguments: [10.0, 100.0])
    func heldOldReceiptIsAcknowledgedOnlyByNewerCommittedSeek(target: Double) async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a", startTime: 50)
        let saving = Gate()
        let persistence = Gate()
        defer { persistence.open() }
        s.syncer.beforePositionPersistence = {
            saving.open()
            await persistence.wait()
        }
        var old: PlaybackCloseHandoff?
        let reporter = s.coordinator.finalCloseReport
        s.coordinator.finalCloseReport = {
            old = reporter?($0)
            return old
        }
        s.coordinator.stop()
        await saving.wait()
        let receipt = try #require(old)
        await s.coordinator.play(itemID: "a", startTime: 50)
        s.h.clock.advance(by: -1)  // Sequence, not wall-clock or maximum time, defines newer.
        await s.coordinator.seek(to: target)
        #expect(receipt.position.result == nil)
        #expect(try await s.store.progress(for: s.h.key("a")) == nil)
        s.syncer.quiesceTransport()
        persistence.open()
        try await receipt.waitForAudioPosition()
        await s.syncer.waitForPendingWrites()
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == target)
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == true)
    }

    @Test func newerFailedEditCannotAcknowledgeSupersededClose() async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a", startTime: 50)
        let saving = Gate()
        let persistence = Gate()
        defer { persistence.open() }
        s.syncer.beforePositionPersistence = {
            saving.open()
            await persistence.wait()
        }
        var handoff: PlaybackCloseHandoff?
        let reporter = s.coordinator.finalCloseReport
        s.coordinator.finalCloseReport = {
            handoff = reporter?($0)
            return handoff
        }
        s.coordinator.stop()
        await saving.wait()
        let receipt = try #require(handoff)
        await s.coordinator.play(itemID: "a", startTime: 50)
        await s.coordinator.seek(to: 100)
        s.syncer.quiesceTransport()
        await s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        persistence.open()
        await #expect(throws: CocoaError.self) { try await receipt.waitForAudioPosition() }
        await s.syncer.waitForPendingWrites()
        // A later queued retry may commit, but cannot turn the failed handoff into a success.
        await #expect(throws: CocoaError.self) { try await receipt.waitForAudioPosition() }
    }

    @Test(arguments: PlaybackLifecycleTests.noNetworkReasons)
    func diskReopenProvesFinalWriteSurvivesCanceledWaiterDetachAndOwnerRelease(reason: PlaybackStopReason) async throws
    {
        let directory = FileManager.default.temporaryDirectory.appending(path: "PlaybackClose-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Audiobookshelf.store")
        let connectionID = UUID()
        let persistence = Gate()
        let saving = Gate()
        defer { persistence.open() }
        weak var oldSyncer: ProgressSyncer?
        weak var oldCoordinator: PlaybackCoordinator?

        func captureAndRelease() async throws -> PlaybackCloseHandoff {
            let stack = try DataStack(location: .url(url))
            let s = try SyncHarness(
                progressStore: LocalProgressStore(modelContainer: stack.container), connectionID: connectionID)
            oldSyncer = s.syncer
            oldCoordinator = s.coordinator
            await s.coordinator.play(itemID: "a", startTime: 50)
            // No tick/periodic report ever occurred.
            s.h.engine.currentTime = 51.25
            s.syncer.beforePositionPersistence = {
                saving.open()
                await persistence.wait()
            }
            var handoff: PlaybackCloseHandoff?
            let reporter = s.coordinator.finalCloseReport
            s.coordinator.finalCloseReport = {
                handoff = reporter?($0)
                return handoff
            }
            s.coordinator.stop(reason: reason)
            await saving.wait()
            let waiter = Task { try await s.coordinator.waitForClose() }
            waiter.cancel()
            await #expect(throws: CancellationError.self) { try await waiter.value }
            let receipt = try #require(handoff)
            #expect(receipt.position.result == nil)
            s.syncer.detach()
            #expect(s.h.service.closes.isEmpty)
            #expect(s.service.reports.isEmpty && s.service.patches.isEmpty)
            return receipt
        }
        let receipt = try await captureAndRelease()
        #expect(oldCoordinator == nil)
        #expect(oldSyncer != nil)  // The queued immutable write, not its canceled waiter, owns persistence.
        persistence.open()
        try await receipt.waitForAudioPosition()
        await yieldUntil { oldSyncer == nil }
        let reopened = try DataStack(location: .url(url))
        let store = LocalProgressStore(modelContainer: reopened.container)
        let key = MediaKey(serverConnectionID: connectionID, libraryItemId: "a")
        let row = try #require(try await store.progress(for: key))
        #expect(row.currentTime == 51.25 && row.needsServerSync)
    }
}
