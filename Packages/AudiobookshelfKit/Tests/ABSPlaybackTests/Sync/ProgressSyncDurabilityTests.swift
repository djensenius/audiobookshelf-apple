import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSData
@testable import ABSPlayback

@MainActor
struct ProgressSyncDurabilityTests {
    @Test(arguments: [false, true])
    func heldReportKeepsLatestPositionDurable(fails: Bool) async throws {
        let s = try SyncHarness()
        let gate = Gate()
        s.service.state.withLock {
            $0.syncGates = [gate]
            $0.syncErrors = fails ? [.network(.cannotConnectToHost)] : []
        }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15, settling: false)
        await s.service.waitForSyncs(1)
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == 15)
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == true)

        await s.coordinator.seek(to: 100)
        s.coordinator.pause()
        await s.syncer.waitForPendingWrites()
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == 100)
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == true)
        #expect(s.service.reports.count == 1)

        gate.open()
        await s.settle()
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == 100)
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == false)
        #expect(s.service.patches.allSatisfy { $0.update == SyncHarness.audio(100) })
    }

    @Test func failedPositionSaveBlocksNetworkAndExplicitDrainRetriesIt() async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a")
        await s.play(for: 14.5)
        await s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        await s.play(for: 0.5)
        await s.settle()
        #expect(s.service.reports.isEmpty)
        #expect(s.service.patches.isEmpty)
        #expect(try await s.store.progress(for: s.h.key("a")) == nil)

        await s.syncer.drainPendingProgress()
        #expect(s.service.patches == [.init(itemID: "a", update: SyncHarness.audio(15))])
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == false)
        await s.play(for: 15)
        #expect(s.service.reports.map(\.timeListened) == [30])
    }

    @Test func heldPatchDoesNotBlockSavingSeek() async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a")
        try await s.store.recordEdit(
            ProgressEdit(audio: .init(currentTime: 50, duration: 3600, progress: 50 / 3600)), for: s.h.key("a"))
        let gate = Gate()
        let started = Gate()
        s.service.state.withLock {
            $0.patchGates = [gate]
            $0.patchStarted = started
        }
        let drain = Task { await s.syncer.drainPendingProgress() }
        await started.wait()
        await s.coordinator.seek(to: 100)
        await s.syncer.waitForPendingWrites()
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == 100)
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == true)
        #expect(s.service.reports.isEmpty)
        gate.open()
        await drain.value
        #expect(s.service.patches.map(\.update) == [SyncHarness.audio(50), SyncHarness.audio(100)])
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == false)
    }

    @Test(arguments: [100.0, 10.0])
    func oldCloseCannotOverwriteReopenedSessionSeek(target: Double) async throws {
        let s = try SyncHarness()
        s.service.state.withLock { $0.syncErrors = [.network(.cannotConnectToHost)] }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 20)
        // B is older, so its PATCH holds the drain ahead of A's dirty position at 15 s.
        try await s.store.recordEdit(
            ProgressEdit(audio: .init(currentTime: 50, duration: 3600, progress: 50 / 3600)),
            for: s.h.key("b"), now: s.h.clock.ago(100))
        let gate = Gate()
        defer { gate.open() }
        let started = Gate()
        s.service.state.withLock {
            $0.patchGates = [gate]
            $0.patchStarted = started
            $0.patchErrors = [.network(.networkConnectionLost)]
        }
        let drain = Task { await s.syncer.drainPendingProgress() }
        await started.wait()
        #expect(s.service.patches.map(\.itemID) == ["b"])

        s.coordinator.stop()
        await s.syncer.waitForPendingWrites()
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == 20)
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == true)
        await s.coordinator.play(itemID: "a", startTime: 20)
        // Event order, not wall-clock order or maximum media time, determines the latest intent.
        s.h.clock.advance(by: -1)
        await s.coordinator.seek(to: target)
        await s.syncer.waitForPendingWrites()
        let saved = try #require(try await s.store.progress(for: s.h.key("a")))
        #expect(saved.currentTime == target)
        #expect(saved.needsServerSync)

        gate.open()
        await drain.value
        let acknowledged = try #require(try await s.store.progress(for: s.h.key("a")))
        #expect(s.service.reports.last?.currentTime == target)
        #expect(s.service.patches.filter { $0.itemID == "a" }.map(\.update) == [SyncHarness.audio(target)])
        #expect(acknowledged.currentTime == target)
        #expect(acknowledged.serverBaseline?.currentTime == target)
        #expect(acknowledged.audioEditedAt == saved.audioEditedAt)
        #expect(!acknowledged.needsServerSync)
    }

    @Test(arguments: [false, true])
    func closeRetainsPendingWorkAfterStoreFailure(initialSaveFails: Bool) async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a")
        await s.play(for: 14.5)
        if initialSaveFails {
            await s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        } else {
            s.service.state.withLock { $0.syncErrors = [.network(.cannotConnectToHost)] }
        }
        await s.play(for: 5.5)
        if !initialSaveFails {
            await s.store.failNextRowFetch(with: CocoaError(.fileReadUnknown))
        }
        s.coordinator.stop()
        await s.settle()

        await s.syncer.drainPendingProgress()
        #expect(s.service.patches == [.init(itemID: "a", update: SyncHarness.audio(20))])
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == 20)
        #expect(try await s.store.pendingSync(for: s.h.connectionID).isEmpty)
    }

    @Test(arguments: [0, 1, 2])
    func qualifiedCloseSurvivesOlderPatchAcknowledgement(saveFailures: Int) async throws {
        let s = try SyncHarness()
        let gate = Gate()
        defer { gate.open() }
        let started = Gate()
        s.service.state.withLock {
            $0.patchGates = [gate]
            $0.patchStarted = started
        }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15, settling: false)
        await started.wait()
        #expect(s.service.patches.map(\.update) == [SyncHarness.audio(15)])
        await s.play(for: 5, settling: false)
        if saveFailures > 0 {
            await s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        }
        s.coordinator.stop()
        await s.syncer.waitForPendingWrites()
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == (saveFailures > 0 ? 15 : 20))
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == true)

        gate.open()
        await s.settle()
        if saveFailures > 0 {
            // The older PATCH cleans 15 s, but the qualified 20 s snapshot still needs saving.
            #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == 15)
            #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == false)
            if saveFailures > 1 {
                await s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
                await s.syncer.drainPendingProgress()
                #expect(s.service.patches.count == 1)
            }
            await s.syncer.drainPendingProgress()
        }
        // A successful save must remove the qualified snapshot, not keep replaying it.
        await s.syncer.drainPendingProgress()
        #expect(s.service.patches.map(\.update) == [SyncHarness.audio(15), SyncHarness.audio(20)])
        let row = try #require(try await s.store.progress(for: s.h.key("a")))
        #expect(row.currentTime == 20)
        #expect(row.serverBaseline?.currentTime == 20)
        #expect(!row.needsServerSync)
    }

    @Test func newerSeekReplacesQualifiedCloseAfterFailedSave() async throws {
        let s = try SyncHarness()
        let gate = Gate()
        defer { gate.open() }
        let started = Gate()
        s.service.state.withLock {
            $0.patchGates = [gate]
            $0.patchStarted = started
        }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15, settling: false)
        await started.wait()
        await s.play(for: 5, settling: false)
        await s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        s.coordinator.stop()
        await s.syncer.waitForPendingWrites()

        await s.coordinator.play(itemID: "a", startTime: 20)
        await s.coordinator.seek(to: 100)
        await s.syncer.waitForPendingWrites()
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == 100)
        gate.open()
        await s.settle()
        await s.syncer.drainPendingProgress()
        #expect(s.service.patches.map(\.update) == [SyncHarness.audio(15), SyncHarness.audio(100)])
        let row = try #require(try await s.store.progress(for: s.h.key("a")))
        #expect(row.currentTime == 100)
        #expect(row.serverBaseline?.currentTime == 100)
        #expect(!row.needsServerSync)
    }

    @Test(arguments: [false, true], [false, true])
    func settlementFailureRetainsOutcomeAndNewerEdit(transportFails: Bool, lookupFails: Bool) async throws {
        let s = try SyncHarness()
        let key = s.h.key("a")
        try await s.store.recordEdit(
            ProgressEdit(audio: .init(currentTime: 50, duration: 3600, progress: 50 / 3600)), for: key)
        let gate = Gate()
        let started = Gate()
        s.service.state.withLock {
            $0.patchGates = [gate]
            $0.patchStarted = started
            $0.patchErrors = transportFails ? [.network(.networkConnectionLost)] : []
        }
        let drain = Task { await s.syncer.drainPendingProgress() }
        await started.wait()
        try await s.store.recordEdit(
            ProgressEdit(audio: .init(currentTime: 80, duration: 3600, progress: 80 / 3600)), for: key)
        if lookupFails {
            await s.store.failNextRowFetch(with: CocoaError(.fileReadUnknown))
        } else {
            await s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        }
        gate.open()
        await drain.value
        #expect(s.service.patches.count == 1)
        #expect(try await s.store.progress(for: key)?.currentTime == 80)
        #expect(try await s.store.progress(for: key)?.needsServerSync == true)

        // A second settlement failure must also retain the original token and outcome.
        if lookupFails {
            await s.store.failNextRowFetch(with: CocoaError(.fileReadUnknown))
            await s.syncer.drainPendingProgress()
            #expect(s.service.patches.count == 1)
        }
        await s.syncer.drainPendingProgress()
        #expect(
            s.service.patches == [
                .init(itemID: "a", update: SyncHarness.audio(50)),
                .init(itemID: "a", update: SyncHarness.audio(80)),
            ])
        #expect(try await s.store.progress(for: key)?.needsServerSync == false)
        #expect(try await s.store.progress(for: key)?.unacknowledgedSends.isEmpty == true)
    }

    @Test func settlementRetryDoesNotResendAcknowledgedPatch() async throws {
        let s = try SyncHarness()
        try await s.store.recordEdit(
            ProgressEdit(isFinished: true), for: s.h.key("a"), now: s.h.clock.now)
        let gate = Gate()
        let started = Gate()
        s.service.state.withLock {
            $0.patchGates = [gate]
            $0.patchStarted = started
        }
        let drain = Task { await s.syncer.drainPendingProgress() }
        await started.wait()
        await s.store.failNextRowFetch(with: CocoaError(.fileReadUnknown))
        gate.open()
        await drain.value
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == true)
        await s.syncer.drainPendingProgress()
        #expect(s.service.patches.count == 1)
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == false)
    }

    @Test func diskReopenRecoversLatestPositionFromHeldReport() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ProgressSync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Audiobookshelf.store")
        let connectionID = UUID()

        // Return without retaining the first container, store, coordinator or syncer.
        func leavePendingPosition() async throws {
            let stack = try DataStack(location: .url(url))
            let s = try SyncHarness(
                progressStore: LocalProgressStore(modelContainer: stack.container), connectionID: connectionID)
            let gate = Gate()
            s.service.state.withLock {
                $0.syncGates = [gate]
                $0.syncErrors = [.timedOut]
            }
            await s.coordinator.play(itemID: "a")
            await s.play(for: 15, settling: false)
            await s.service.waitForSyncs(1)
            await s.coordinator.seek(to: 100)
            await s.syncer.waitForPendingWrites()
            // End the held transport without allowing the old owner to drain the queue.
            s.syncer.detach()
            gate.open()
            await s.settle()
        }
        try await leavePendingPosition()

        let reopened = try DataStack(location: .url(url))
        let s = try SyncHarness(
            progressStore: LocalProgressStore(modelContainer: reopened.container), connectionID: connectionID)
        let row = try #require(try await s.store.progress(for: s.h.key("a")))
        #expect(row.currentTime == 100)
        #expect(row.needsServerSync)
        await s.syncer.drainPendingProgress()
        #expect(s.service.reports.isEmpty)
        #expect(s.service.patches == [.init(itemID: "a", update: SyncHarness.audio(100))])
        #expect(try await s.store.pendingSync(for: connectionID).isEmpty)
    }

    @Test func diskReopenDrainsUnsettledPatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ProgressSync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Audiobookshelf.store")
        let connectionID = UUID()
        let key = MediaKey(serverConnectionID: connectionID, libraryItemId: "a", episodeId: "e1")

        func leaveUnsettledPatch() async throws {
            let stack = try DataStack(location: .url(url))
            let s = try SyncHarness(
                progressStore: LocalProgressStore(modelContainer: stack.container), connectionID: connectionID)
            try await s.store.recordEdit(
                ProgressEdit(audio: .init(currentTime: 50, duration: 3600, progress: 50 / 3600)), for: key)
            let gate = Gate()
            let started = Gate()
            s.service.state.withLock {
                $0.patchGates = [gate]
                $0.patchStarted = started
            }
            let drain = Task { await s.syncer.drainPendingProgress() }
            await started.wait()
            await s.store.failNextRowFetch(with: CocoaError(.fileReadUnknown))
            gate.open()
            await drain.value
            s.syncer.detach()
        }
        try await leaveUnsettledPatch()

        let reopened = try DataStack(location: .url(url))
        let s = try SyncHarness(
            progressStore: LocalProgressStore(modelContainer: reopened.container), connectionID: connectionID)
        let row = try #require(try await s.store.progress(for: key))
        #expect(row.needsServerSync)
        #expect(row.unacknowledgedSends.count == 1)
        await s.syncer.drainPendingProgress()
        #expect(s.service.patches == [.init(itemID: "a", episodeID: "e1", update: SyncHarness.audio(50))])
        #expect(try await s.store.pendingSync(for: connectionID).isEmpty)
    }
}
