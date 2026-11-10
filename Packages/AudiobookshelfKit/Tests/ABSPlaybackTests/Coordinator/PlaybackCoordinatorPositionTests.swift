import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// The position while a seek the engine couldn't finish is pending: its target, not the engine's
/// own time (0 after a load), is where playback is going.
@MainActor
struct PlaybackCoordinatorPositionTests {
    let h: CoordinatorHarness
    var coordinator: PlaybackCoordinator { h.coordinator }
    var engine: CoordinatorTestEngine { h.engine }

    init() throws {
        h = try CoordinatorHarness()
    }

    private var seekTimes: [Double] {
        h.events.events.compactMap {
            guard case .didSeek(let time) = $0 else { return nil }
            return time
        }
    }

    // MARK: - Interrupted initial seek

    @Test func interruptedInitialSeekIsReportedAndSavedAtItsTarget() async throws {
        engine.interruptedLoads = 1

        await coordinator.play(itemID: "A", startTime: 1500)

        #expect(coordinator.phase == .loaded)
        #expect(engine.currentTime == 0)
        #expect(coordinator.currentTime == 1500)
        #expect(coordinator.chapterIndex == 1)
        #expect(
            h.events.events == [
                .itemChanged(h.key("A")), .sessionStarted(sessionID: "A-1", key: h.key("A")),
                .loaded(time: 1500), .playbackStarted,
            ])
        let saved = try #require(h.lastPlayed.record)
        #expect(saved.position == 1500)
    }

    @Test(arguments: [false, true])
    func closingBeforeTheInitialSeekLandsReportsTheTarget(stopping: Bool) async {
        var closing: [ClosingSession] = []
        coordinator.finalCloseReport = {
            closing.append($0)
            return PlaybackSyncReport(currentTime: $0.currentTime, timeListened: 0, duration: $0.duration)
                .map { PlaybackCloseHandoff(report: $0, position: PlaybackCloseResult()) }
        }
        engine.interruptedLoads = 1
        await coordinator.play(itemID: "A", startTime: 1500)

        if stopping {
            coordinator.stop()
        } else {
            await coordinator.play(itemID: "B")
        }

        #expect(closing.map(\.currentTime) == [1500])
        #expect(closing.map(\.reason) == [stopping ? .stopped : .itemChanged])
    }

    @Test func landingConfirmsTheSeekExactlyOnceAndSavesIt() async throws {
        engine.interruptedLoads = 1
        await coordinator.play(itemID: "A", startTime: 1500)
        let loaded = h.events.count
        h.clock.advance(by: 20)

        engine.landPendingSeek()

        #expect(h.events.since(loaded) == [.didSeek(time: 1500), .tick(time: 1500)])
        #expect(coordinator.isPlaying)
        let saved = try #require(h.lastPlayed.record)
        #expect(saved.position == 1500)
        #expect(saved.timestamp == h.clock.now)

        // Later ticks are only ticks.
        engine.currentTime = 1501
        engine.onEvent?(.tick(1501))
        #expect(seekTimes == [1500])
    }

    @Test func playbackPausedDuringTheLoadNeverReportsASeekToZero() async throws {
        engine.interruptedLoads = 1
        let gate = Gate()
        engine.loadGates = [gate]
        let play = Task { await coordinator.play(itemID: "A", startTime: 1500) }
        await yieldUntil { engine.loads.count == 1 }

        coordinator.pause()
        gate.open()
        await play.value

        #expect(coordinator.phase == .loaded)
        #expect(!engine.isPlaybackRequested)
        #expect(coordinator.currentTime == 1500)
        #expect(
            h.events.events == [
                .itemChanged(h.key("A")), .sessionStarted(sessionID: "A-1", key: h.key("A")), .loaded(time: 1500),
            ])
        let saved = try #require(h.lastPlayed.record)
        #expect(saved.position == 1500)

        // Resuming seeks to the target itself, and that is the first seek reported.
        await coordinator.resume()
        #expect(engine.seeks == [1500])
        #expect(seekTimes == [1500])
        #expect(coordinator.isPlaying)
    }

    @Test func seekCompletingBeforeTheLandingTakesItsPlace() async {
        engine.interruptedLoads = 1
        await coordinator.play(itemID: "A", startTime: 1500)

        #expect(await coordinator.seek(to: 2000) == 2000)
        engine.currentTime = 2001
        engine.onEvent?(.tick(2001))

        #expect(seekTimes == [2000])
    }

    @Test func stoppingFromLoadedObserverDoesNotReportASeek() async {
        _ = coordinator.addObserver { event in
            if case .loaded = event { coordinator.stop() }
        }

        await coordinator.play(itemID: "A")

        #expect(coordinator.phase == .idle)
        #expect(h.events.events.contains(.itemChanged(nil)))
        #expect(!h.events.events.contains { if case .didSeek = $0 { true } else { false } })
    }

    // MARK: - Resume

    @Test(arguments: [nil, 15.0] as [Double?])
    func resumeSeeksToAnInterruptedTargetNotARewoundOldPosition(rewindingBy: Double?) async {
        await coordinator.play(itemID: "A", startTime: 1000)
        coordinator.pause()
        h.clock.advance(by: 120)
        engine.seekResults = [.interrupted]
        #expect(await coordinator.seek(to: 2000) == nil)
        #expect(coordinator.currentTime == 2000)
        var willResumeCalls = 0
        coordinator.willResume = {
            willResumeCalls += 1
            return 30
        }
        let paused = h.events.count

        await coordinator.resume(rewindingBy: rewindingBy)

        #expect(willResumeCalls == 1)
        #expect(engine.seeks == [2000, 2000])
        #expect(coordinator.currentTime == 2000)
        #expect(coordinator.isPlaying)
        #expect(h.events.since(paused) == [.didSeek(time: 2000), .playbackStarted])
    }

    @Test func resumeRecoversAnInterruptedSeekWhilePlaybackIsStillRequested() async throws {
        await coordinator.play(itemID: "A", startTime: 1000)
        engine.seekResults = [.interrupted]
        #expect(await coordinator.seek(to: 2000) == nil)
        #expect(engine.isPlaybackRequested && engine.state == .buffering)

        await coordinator.resume()

        #expect(engine.seeks == [2000, 2000])
        #expect(coordinator.isPlaying)
    }

    @Test func resumedSeekLandingIsReportedAfterTwoInterruptions() async throws {
        await coordinator.play(itemID: "A", startTime: 1000)
        engine.seekResults = [.interrupted, .interrupted]
        #expect(await coordinator.seek(to: 2000) == nil)
        let resumed = h.events.count

        await coordinator.resume()
        #expect(engine.pendingSeekTarget == 2000)
        engine.landPendingSeek()

        #expect(
            h.events.since(resumed) == [
                .playbackStarted, .didSeek(time: 2000), .tick(time: 2000),
            ])
        #expect(seekTimes.filter { $0 == 2000 }.count == 1)
    }

    @Test func resumeAfterTheEndStillSeeksToAnInterruptedTarget() async {
        await coordinator.play(itemID: "A", startTime: 3500)
        engine.finish()
        engine.seekResults = [.interrupted]
        #expect(await coordinator.seek(to: 2000) == nil)

        await coordinator.resume()

        // Not the restart from 0 an ended item gets.
        #expect(engine.seeks == [2000, 2000])
        #expect(coordinator.currentTime == 2000)
        #expect(coordinator.isPlaying)
    }

    @Test func endedItemSavedBeforeInterruptedBackwardSeekLandsRestoresItsTarget() async throws {
        await coordinator.play(itemID: "A", startTime: 3500)
        engine.finish()
        engine.seekResults = [.interrupted]
        #expect(await coordinator.seek(to: 2000) == nil)

        coordinator.saveLastPlayed()

        let saved = try #require(h.lastPlayed.record)
        #expect(saved.position == 2000)
        #expect(!saved.isFinished)
        let relaunched = try CoordinatorHarness(lastPlayed: h.lastPlayed, connectionID: h.connectionID)
        #expect(relaunched.coordinator.restoreLastPlayed())
        await relaunched.coordinator.resume()
        #expect(relaunched.engine.loads.map(\.time) == [2000])
    }

    @Test func explicitStartTimeBeatsAnInterruptedTarget() async {
        await coordinator.play(itemID: "A", startTime: 1000)
        coordinator.pause()
        engine.seekResults = [.interrupted]
        #expect(await coordinator.seek(to: 2000) == nil)

        await coordinator.play(itemID: "A", startTime: 3000)

        #expect(engine.seeks == [2000, 3000])
        #expect(coordinator.currentTime == 3000)
        #expect(coordinator.isPlaying)
        engine.onEvent?(.tick(3001))
        #expect(seekTimes == [1000, 3000])
    }
}
