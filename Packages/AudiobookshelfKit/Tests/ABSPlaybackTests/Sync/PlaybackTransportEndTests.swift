import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSData
@testable import ABSPlayback

@MainActor
struct PlaybackTransportEndTests {
    @Test(arguments: PlaybackLifecycleTests.noNetworkReasons)
    func endBeforeQueuedSyncRunsSavesFinalPositionWithoutIssuingTransport(reason: PlaybackStopReason) async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a")
        let saving = Gate()
        let persistence = Gate()
        defer { persistence.open() }
        s.syncer.beforePositionPersistence = {
            saving.open()
            await persistence.wait()
        }
        await s.coordinator.seek(to: 500)
        await saving.wait()
        s.h.engine.currentTime = 501
        s.coordinator.stop(reason: reason)
        persistence.open()
        let outcome = try await s.coordinator.waitForClose()
        await s.settle()
        #expect(outcome.sessions.first?.transport == .deliberatelySkipped)
        #expect(s.h.service.closes.isEmpty)
        #expect(s.service.reports.isEmpty && s.service.patches.isEmpty)
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == 501)
        await s.syncer.drainPendingProgress()
        #expect(s.service.patches.isEmpty)
    }

    @Test(arguments: PlaybackLifecycleTests.noNetworkReasons, [false, true])
    func issuedSyncOrPatchMayFinishButCannotStartQueuedWork(reason: PlaybackStopReason, patch: Bool) async throws {
        let s = try SyncHarness()
        let issued = Gate()
        let request = Gate()
        defer { request.open() }
        if patch {
            s.service.state.withLock {
                $0.patchGates = [request]
                $0.patchStarted = issued
            }
        } else {
            s.service.state.withLock { $0.syncGates = [request] }
        }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15, settling: false)
        if patch { await issued.wait() } else { await s.service.waitForSyncs(1) }
        await s.coordinator.seek(to: 100)
        s.coordinator.stop(reason: reason)
        let outcome = try await s.coordinator.waitForClose()
        #expect(outcome.sessions.first?.audioPositionCommitted == true)
        #expect(s.service.reports.count == 1)
        #expect(s.service.patches.count == (patch ? 1 : 0))
        request.open()
        await s.settle()
        await s.syncer.drainPendingProgress()
        #expect(s.service.reports.count == 1)
        #expect(s.service.patches.count == (patch ? 1 : 0))
        #expect(s.h.service.closes.isEmpty)
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == 100)
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == true)
        #expect(s.service.state.withLock { $0.canceledCalls } == (patch ? ["patch"] : ["sync"]))
    }

    @Test(arguments: [false, true])
    func expiryJoinsOldCloseAndSuppressesUnissuedRequest(alreadyIssued: Bool) async throws {
        let s = try SyncHarness()
        let gate = Gate()
        defer { gate.open() }
        await s.coordinator.play(itemID: "a", startTime: 50)
        s.h.service.state.withLock { $0.closeGates["a-1"] = gate }
        s.coordinator.stop()
        if alreadyIssued { await yieldUntil { s.h.service.closes == ["a-1"] } }
        s.coordinator.stop(reason: .expired)
        let outcome = try await s.coordinator.waitForClose()
        #expect(outcome.sessions.first?.transport == .deliberatelySkipped)
        #expect(outcome.sessions.first?.audioPositionCommitted == true)
        #expect(s.h.service.closes == (alreadyIssued ? ["a-1"] : []))
        gate.open()
        await s.coordinator.waitForPendingCloses()
        #expect(s.h.service.closes == (alreadyIssued ? ["a-1"] : []))
        #expect(s.h.service.state.withLock { $0.canceledCloses } == (alreadyIssued ? ["a-1"] : []))
    }
}
