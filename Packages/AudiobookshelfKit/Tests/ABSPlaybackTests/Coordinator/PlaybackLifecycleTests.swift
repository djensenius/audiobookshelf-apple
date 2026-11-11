import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

@MainActor
struct PlaybackLifecycleTests {
    nonisolated static let accountReasons: [PlaybackStopReason] = [.accountSwitch, .expired, .signOut, .accountRemoved]
    nonisolated static let noNetworkReasons: [PlaybackStopReason] = [.expired, .signOut, .accountRemoved]

    @Test func invalidLoadedPositionDoesNotReplaceValidLastPlayed() async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a", startTime: 42)
        let saved = s.h.lastPlayed.record
        s.h.engine.currentTime = .nan
        s.coordinator.stop(reason: .expired)
        #expect(s.h.lastPlayed.record == saved)
        await #expect(throws: PlaybackCloseError.missingReporter(sessionID: "a-1")) {
            try await s.coordinator.waitForClose()
        }
    }

    @Test(arguments: noNetworkReasons)
    func lateStreamResolutionIsCanceledAndNeverLoadsOrCloses(reason: PlaybackStopReason) async throws {
        let h = try CoordinatorHarness()
        let gate = Gate()
        defer { gate.open() }
        h.service.state.withLock { $0.resolveGate = gate }
        let play = Task { await h.coordinator.play(itemID: "a") }
        await yieldUntil { h.service.state.withLock { $0.resolutions == 1 } }
        h.coordinator.stop(reason: reason)
        gate.open()
        await play.value
        await h.coordinator.waitForPendingCloses()
        #expect(h.service.closes.isEmpty)
        #expect(h.engine.loads.isEmpty)
        #expect(h.service.state.withLock { $0.canceledResolutions } == 1)
        #expect(h.coordinator.phase == .idle)
    }

    @Test(arguments: [.user] + accountReasons)
    func loadedStopCapturesBeforeResetAndRetiresOnlyAccountEnd(reason: PlaybackStopReason) async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a", startTime: 42)
        s.h.clock.advance(by: 0.25)
        s.h.engine.currentTime = 42.25
        var report: PlaybackCloseHandoff?
        var order: [String] = []
        let reporter = s.coordinator.finalCloseReport
        s.coordinator.finalCloseReport = {
            #expect(s.coordinator.confirmedPlaybackTime == 42.25)
            order.append("capture")
            report = reporter?($0)
            return report
        }
        _ = s.coordinator.addObserver {
            if case .sessionWillClose = $0 {
                #expect(report != nil)
                order.append("event")
            }
        }
        s.coordinator.stop(reason: reason)
        #expect(order == ["capture", "event"])
        #expect(s.coordinator.phase == .idle)
        #expect(s.h.engine.state == .idle)
        #expect(s.coordinator.isRetired == (reason != .user))
        #expect(report?.report.currentTime == 42.25)
        #expect(report?.report.timeListened == 0.25)
        let retained = reason == .accountSwitch || reason == .expired
        #expect(s.h.lastPlayed.record?.position == (retained ? 42.25 : nil))
        #expect(s.h.lastPlayed.record?.title == (retained ? "Title a" : nil))
        let outcome = try await s.coordinator.waitForClose()
        #expect(outcome.sessions.count == 1)
        #expect(outcome.sessions.first?.audioPositionCommitted == true)
        #expect(outcome.sessions.first?.transport == (reason.permitsTransport ? .acknowledged : .deliberatelySkipped))
        #expect(s.h.service.closes == (reason.permitsTransport ? ["a-1"] : []))
        #expect(s.service.reports.isEmpty && s.service.patches.isEmpty)
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == 42.25)
        s.coordinator.finalCloseReport = reporter
        await s.coordinator.play(itemID: "b")
        #expect(s.h.service.starts == (reason == .user ? ["a", "b"] : ["a"]))
        if reason == .user { s.coordinator.stop() }
        await s.coordinator.waitForPendingCloses()
        await s.settle()
    }

    @Test(arguments: accountReasons, [false, true])
    func accountEndNeverChangesAnotherConnectionsRecord(reason: PlaybackStopReason, loaded: Bool) async throws {
        let s = try SyncHarness()
        if loaded { await s.coordinator.play(itemID: "a") }
        var other = s.h.record("other", position: 555, age: 100)
        other.serverConnectionID = UUID()
        s.h.lastPlayed.record = other
        s.coordinator.stop(reason: reason)
        #expect(s.h.lastPlayed.record == other)
        _ = try await s.coordinator.waitForClose()
        #expect(!s.coordinator.restoreLastPlayed())
        await s.coordinator.resume()
        await s.coordinator.play(itemID: "a")
        #expect(s.coordinator.phase == .idle)
        #expect(s.h.lastPlayed.record == other)
    }

    @Test(arguments: accountReasons, [0, 1, 2])
    func restoredMetadataAndValidIntentSurviveWithoutNetwork(reason: PlaybackStopReason, edit: Int) async throws {
        let h = try CoordinatorHarness()
        let record = h.record("a", position: 200, age: 100)
        h.lastPlayed.record = record
        #expect(h.coordinator.restoreLastPlayed())
        if edit == 1 { await h.coordinator.seek(to: 500) }
        if edit == 2 { await h.coordinator.jump(by: 30) }
        h.coordinator.stop(reason: reason)
        if reason == .accountSwitch || reason == .expired {
            #expect(h.lastPlayed.record?.position == [200.0, 500, 230][edit])
            #expect(h.lastPlayed.record?.title == record.title)
            #expect(h.lastPlayed.record?.timestamp == (edit == 0 ? record.timestamp : h.clock.now))
        } else {
            #expect(h.lastPlayed.record == nil)
        }
        #expect(try await h.coordinator.waitForClose().sessions.isEmpty)
        #expect(h.service.starts.isEmpty && h.service.closes.isEmpty)
    }

    @Test(arguments: accountReasons)
    func idleAccountEndAppliesMatchingRecordPolicy(reason: PlaybackStopReason) async throws {
        let h = try CoordinatorHarness()
        let record = h.record("a", position: 200, age: 100)
        h.lastPlayed.record = record
        h.coordinator.stop(reason: reason)
        #expect(h.lastPlayed.record == (reason == .accountSwitch || reason == .expired ? record : nil))
        #expect(try await h.coordinator.waitForClose().sessions.isEmpty)
        h.coordinator.stop()  // A retired scope cannot clear a later account's record.
        #expect(h.lastPlayed.record == (reason == .accountSwitch || reason == .expired ? record : nil))
    }

    @Test(arguments: [false, true], [PlaybackStopReason.accountSwitch, .expired])
    func unresolvedStartNeverWritesZeroOrRelativeJumpAsPosition(explicit: Bool, reason: PlaybackStopReason) async throws
    {
        let h = try CoordinatorHarness()
        let saved = h.record("previous", position: 200, age: 100)
        h.lastPlayed.record = saved
        let gate = Gate()
        defer { gate.open() }
        h.service.state.withLock { $0.startGates["a"] = gate }
        let play = Task { await h.coordinator.play(itemID: "a", startTime: explicit ? 80 : nil) }
        await yieldUntil { h.service.starts == ["a"] }
        await h.coordinator.jump(by: 30)
        h.coordinator.stop(reason: reason)
        #expect(h.lastPlayed.record?.position == (explicit ? 110 : saved.position))
        #expect(h.lastPlayed.record?.libraryItemID == (explicit ? "a" : "previous"))
        gate.open()
        await play.value
        await h.coordinator.waitForPendingCloses()
        #expect(h.service.closes == (reason == .accountSwitch ? ["a-1"] : []))
        #expect(h.engine.loads.isEmpty)
        #expect(h.coordinator.phase == .idle)
    }

    @Test(arguments: [false, true])
    func pendingSeekAndJumpDuringLoadPreserveLatestResolvedIntent(explicit: Bool) async throws {
        let h = try CoordinatorHarness()
        h.settings.disableAutoRewind = true
        h.service.state.withLock { $0.serverTime["a"] = 200 }
        let gate = Gate()
        defer { gate.open() }
        h.engine.loadGates = [gate]
        let play = Task { await h.coordinator.play(itemID: "a") }
        await yieldUntil { h.engine.loads.count == 1 }
        if explicit { await h.coordinator.seek(to: 500) }
        await h.coordinator.jump(by: 30)
        h.coordinator.stop(reason: .expired)
        #expect(h.lastPlayed.record?.position == (explicit ? 530 : 230))
        gate.open()
        await play.value
        #expect(h.coordinator.phase == .idle)
        #expect(!h.engine.isPlaybackRequested)
        #expect(h.service.closes.isEmpty)
        #expect(try await h.coordinator.waitForClose().sessions.first?.transport == .deliberatelySkipped)
    }

    @Test(arguments: [false, true])
    func loadedInterruptedSeekAndJumpPreserveTarget(jump: Bool) async throws {
        let s = try SyncHarness()
        await s.coordinator.play(itemID: "a", startTime: 200)
        s.h.engine.seekResults = [.interrupted]
        if jump { await s.coordinator.jump(by: 30) } else { await s.coordinator.seek(to: 600) }
        s.coordinator.stop(reason: .expired)
        #expect(s.h.lastPlayed.record?.position == (jump ? 230 : 600))
        _ = try await s.coordinator.waitForClose()
        #expect(try await s.store.progress(for: s.h.key("a"))?.currentTime == (jump ? 230 : 600))
    }

    @Test(arguments: noNetworkReasons)
    func queuedStartsAndLateCleanupNeverIssueAfterNoNetworkEnd(reason: PlaybackStopReason) async throws {
        let h = try CoordinatorHarness()
        let gate = Gate()
        defer { gate.open() }
        h.service.state.withLock { $0.startGates["a"] = gate }
        let first = Task { await h.coordinator.play(itemID: "a") }
        await yieldUntil { h.service.starts == ["a"] }
        let second = Task { await h.coordinator.play(itemID: "b") }
        await yieldUntil { h.coordinator.queuedSessionStarts == 1 }
        h.coordinator.stop(reason: reason)
        gate.open()  // Already-issued bytes can still create a session.
        await first.value
        await second.value
        await h.coordinator.waitForPendingCloses()
        #expect(h.service.starts == ["a"])
        #expect(h.service.closes.isEmpty)
        #expect(h.service.openSessions == ["a-1"])
        #expect(h.engine.loads.isEmpty)
        #expect(h.coordinator.isRetired && h.coordinator.phase == .idle)
    }

    @Test func pendingPolicyAndReentrantResumeCannotReactivateRetiredCoordinator() async throws {
        let h = try CoordinatorHarness()
        let gate = Gate()
        h.policy.gate = gate
        let play = Task { await h.coordinator.play(itemID: "a") }
        await yieldUntil { h.policy.checks == 1 }
        h.coordinator.stop(reason: .signOut)
        gate.open()
        await play.value
        #expect(h.service.starts.isEmpty)
        #expect(h.coordinator.phase == .idle)

        let s = try SyncHarness()
        s.coordinator.willResume = {
            s.coordinator.stop(reason: .expired)
            return 0
        }
        await s.coordinator.play(itemID: "a")
        #expect(s.h.engine.loads.isEmpty)
        #expect(s.coordinator.isRetired && s.coordinator.phase == .idle)
        #expect(s.h.service.closes.isEmpty)
    }
}
