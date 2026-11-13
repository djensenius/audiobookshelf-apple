import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSPlayback

/// Holds the coordinator's local lookup after session creation, without blocking the syncer's writer.
private struct HeldStartProgressReader: LocalProgressReading {
    let store: LocalProgressStore
    let entered = Gate()
    let release = Gate()

    func progress(for key: MediaKey) async throws -> LocalMediaProgressDTO? {
        entered.open()
        await release.wait()
        return try await store.progress(for: key)
    }

    func captureStartProgress(for key: MediaKey) async throws -> PlaybackStartProgressCapture {
        try await store.captureStartProgress(for: key)
    }

    func applyStartProgressChange(
        _ progress: MediaProgress, captured: PlaybackStartProgressCapture
    ) async throws -> ServerAudioPositionChange? {
        try await store.applyStartProgressChange(progress, captured: captured)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProgressSyncerStartingPauseTests {
    @Test(arguments: [false, true])
    func pauseDuringProgressResolutionDoesNotSaveOrSendPlaceholder(interruptedLoad: Bool) async throws {
        let store = try LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
        let reader = HeldStartProgressReader(store: store)
        defer { reader.release.open() }
        let h = try CoordinatorHarness(progressStore: store, progressReader: reader)
        h.settings.disableAutoRewind = true
        h.engine.interruptedLoads = interruptedLoad ? 1 : 0
        h.setServerProgress("a", time: 1200, updated: h.clock.ago(60))
        try await h.setLocalProgress("a", time: 800, updated: h.clock.ago(120))
        let saved = try await store.progress(for: h.key("a"))
        let before = try #require(saved)
        let service = StubProgressSyncService(serverConnectionID: h.connectionID)
        let clock = h.clock
        let syncer = ProgressSyncer(
            source: h.coordinator, service: service, store: store,
            clock: ProgressSyncClock(now: { clock.now }, uptime: { clock.now.timeIntervalSince1970 }))
        defer { syncer.detach() }
        let coordinator = h.coordinator
        let play = Task { await coordinator.play(itemID: "a") }
        await reader.entered.wait()
        #expect(coordinator.phase == .starting)
        #expect(h.events.events.last == .sessionStarted(sessionID: "a-1", key: h.key("a")))
        #expect(h.engine.loads.isEmpty)
        #expect(coordinator.currentTime == 0, "Display placeholder, not a resolved playback position")

        coordinator.pause()
        #expect(h.events.events.last == .paused(time: 0), "The timer must still observe every pause")
        await syncer.waitForIdle()

        #expect(try await store.progress(for: h.key("a")) == before)
        #expect(service.reports.isEmpty, "Do not replace server progress with the display placeholder")
        #expect(service.patches.isEmpty)
        #expect(h.lastPlayed.record == nil)

        reader.release.open()
        await play.value
        await syncer.waitForIdle()
        #expect(coordinator.phase == .loaded)
        #expect(!coordinator.isPlaybackRequested)
        #expect(h.engine.loads.map(\.time) == [1200], "The newer server progress must still win")
        #expect(coordinator.currentTime == 1200)
        #expect(h.lastPlayed.record?.position == 1200)
        let baseline = try #require(try await store.progress(for: h.key("a")))
        #expect(baseline.currentTime == 1200)
        #expect(baseline.serverBaseline?.currentTime == 1200)
        #expect(baseline.dirtyGroups.isEmpty)
        #expect(baseline.unacknowledgedSends.isEmpty)
        #expect(await store.needsConfirmationFetch.isEmpty)
        #expect(service.reports.isEmpty)
        #expect(service.patches.isEmpty)

        // Once loaded, every pause still persists/reports a valid position. An interrupted load's
        // pending target is valid even though the engine's confirmed clock is still zero.
        #expect(coordinator.confirmedPlaybackTime == (interruptedLoad ? nil : 1200))
        #expect(coordinator.pendingSeekTarget == (interruptedLoad ? 1200 : nil))
        // PATCH is recording-only: explicitly provide pre-drain and post-ACK canonical replies.
        let canonical = try #require(h.service.state.withLock { $0.progress["a"] })
        var acknowledged = canonical
        acknowledged.progress = 1200.0 / 3600
        acknowledged.lastUpdate = Int(clock.now.timeIntervalSince1970 * 1000)
        service.state.withLock { $0.fetchReplies = [canonical, acknowledged] }
        coordinator.pause()
        await syncer.waitForIdle()
        #expect(service.reports.map(\.currentTime) == [1200])
        #expect(service.reports.map(\.timeListened) == [0])
        #expect(service.patches.map(\.update) == [SyncHarness.audio(1200)])
        #expect(try await store.progress(for: h.key("a"))?.currentTime == 1200)
        #expect(try await store.progress(for: h.key("a"))?.needsServerSync == false)
        #expect(service.state.withLock { $0.fetches } == [h.key("a"), h.key("a")])
        #expect(await store.needsConfirmationFetch.isEmpty)

        await coordinator.resume(rewindingBy: 0)
        await syncer.waitForIdle()
        #expect(coordinator.isPlaying)
        #expect(h.engine.currentTime == 1200)
        #expect(h.engine.seeks == (interruptedLoad ? [1200] : []))
        #expect(service.reports.map(\.currentTime) == [1200], "Landing the initial seek adds no new sync")
        #expect(service.patches.map(\.update) == [SyncHarness.audio(1200)])
    }
}
