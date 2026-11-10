import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSPlayback

/// `jump(by:)` and `isPlaybackRequested`, which remote commands (Now Playing) rely on.
@MainActor
struct PlaybackCoordinatorJumpTests {
    let h: CoordinatorHarness
    var coordinator: PlaybackCoordinator { h.coordinator }
    var engine: CoordinatorTestEngine { h.engine }

    init() throws {
        h = try CoordinatorHarness()
        h.settings.disableAutoRewind = true
    }

    /// Starts playing `itemID` with its session start held; returns once the coordinator waits on it.
    private func playHeld(_ itemID: String) async -> (task: Task<Void, Never>, gate: Gate) {
        let gate = Gate()
        h.service.state.withLock { $0.startGates[itemID] = gate }
        let coordinator = coordinator
        let task = Task { await coordinator.play(itemID: itemID) }
        await yieldUntil { h.service.starts.last == itemID && coordinator.phase == .starting }
        return (task, gate)
    }

    private var startCount: Int { h.events.events.count { $0 == .playbackStarted } }

    // MARK: - Jumps

    @Test func jumpAfterAnUnloadedSeekMovesTheChosenPosition() async throws {
        h.lastPlayed.record = h.record("a", position: 120, age: 3600)
        coordinator.restoreLastPlayed()
        await coordinator.seek(to: 200)
        #expect(await coordinator.jump(by: 30) == 230)
        #expect(coordinator.currentTime == 230)

        await coordinator.resume()
        #expect(engine.loads.last?.time == 230)
        #expect(engine.seeks.isEmpty)
    }

    @Test func unloadedJumpsStayWithinTheItemAndMatchTheResume() async throws {
        h.lastPlayed.record = h.record("a", position: 3590, age: 3600)
        coordinator.restoreLastPlayed()
        await coordinator.jump(by: 30)
        #expect(coordinator.currentTime == 3600)
        await coordinator.jump(by: -30)
        #expect(coordinator.currentTime == 3570)

        await coordinator.resume()
        #expect(engine.loads.last?.time == 3590)
        #expect(engine.seeks == [3570])
        #expect(coordinator.currentTime == 3570)
    }

    @Test func aFailedStartDropsUnloadedJumpsFromThePositionShown() async throws {
        h.lastPlayed.record = h.record("a", position: 120, age: 3600)
        coordinator.restoreLastPlayed()
        await coordinator.jump(by: 30)
        #expect(coordinator.currentTime == 150)

        h.service.state.withLock { $0.startError = .forbidden(message: nil) }
        await coordinator.resume()
        #expect(coordinator.error != nil)
        #expect(coordinator.phase == .unloaded)
        #expect(coordinator.currentTime == 120)
    }

    @Test func jumpsAndASeekWhileStartingCombine() async throws {
        h.setServerProgress("a", time: 500, updated: h.clock.ago(10))
        let (play, gate) = await playHeld("a")

        #expect(await coordinator.jump(by: 30) == nil)
        // An absolute seek replaces earlier jumps; later jumps are relative to it.
        #expect(await coordinator.seek(to: 1000) == nil)
        await coordinator.jump(by: -15)
        gate.open()
        await play.value

        // The seek is an explicit start; the later jump applies after the load.
        #expect(engine.loads.last?.time == 1000)
        #expect(engine.seeks == [985])
        #expect(coordinator.currentTime == 985)
        #expect(coordinator.isPlaying)
    }

    // MARK: - Play intent

    @Test func pauseBeforeTheEngineStartsCancelsThePlay() async throws {
        let (play, gate) = await playHeld("a")
        await coordinator.jump(by: 30)
        let seekGate = Gate()
        engine.seekGates = [seekGate]
        gate.open()
        await yieldUntil { engine.seeks == [30] }

        // Loaded, with the catch-up seek in flight: play is requested, but the engine hasn't started.
        #expect(coordinator.phase == .loaded)
        #expect(coordinator.isPlaybackRequested)
        #expect(!coordinator.hasStartedEngine)
        coordinator.pause()
        #expect(!coordinator.isPlaybackRequested)
        seekGate.open()
        await play.value

        #expect(!coordinator.isPlaying)
        #expect(!engine.isPlaybackRequested)
        #expect(!coordinator.hasStartedEngine)
        #expect(startCount == 0)

        await coordinator.resume()
        #expect(coordinator.isPlaying)
        #expect(coordinator.hasStartedEngine)
        #expect(startCount == 1)
    }

    @Test func pauseThenResumeBeforeTheEngineStartsPlaysOnceAfterTheSeek() async throws {
        let (play, gate) = await playHeld("a")
        await coordinator.jump(by: 30)
        let seekGate = Gate()
        engine.seekGates = [seekGate]
        gate.open()
        await yieldUntil { engine.seeks == [30] }

        coordinator.pause()
        await coordinator.resume()
        #expect(coordinator.isPlaybackRequested)
        #expect(!coordinator.isPlaying)
        seekGate.open()
        await play.value

        #expect(coordinator.isPlaying)
        #expect(engine.seeks == [30])
        #expect(startCount == 1)
    }

    @Test func playIsRequestedDuringAResumeSeek() async throws {
        await coordinator.play(itemID: "a")
        engine.currentTime = 100
        coordinator.pause()
        #expect(!coordinator.isPlaybackRequested)

        let gate = Gate()
        engine.seekGates = [gate]
        let coordinator = coordinator
        let resume = Task { await coordinator.resume(rewindingBy: 10) }
        await yieldUntil { engine.seeks.last == 90 }
        #expect(coordinator.isPlaybackRequested)
        #expect(!coordinator.isPlaying)
        gate.open()
        await resume.value
        #expect(coordinator.isPlaying)
    }

    @Test func pauseCancelsAPlayWaitingOnTheStreamingPolicy() async throws {
        await coordinator.play(itemID: "a")
        let gate = Gate()
        h.policy.gate = gate
        let coordinator = coordinator
        let play = Task { await coordinator.play(itemID: "b") }
        await yieldUntil { coordinator.pendingPlayKey == h.key("b") }
        #expect(coordinator.isPlaybackRequested)

        coordinator.pause()
        #expect(coordinator.pendingPlayKey == nil)
        #expect(!coordinator.isPlaybackRequested)
        #expect(!coordinator.isPlaying)
        gate.open()
        await play.value

        #expect(coordinator.mediaKey == h.key("a"))
        #expect(h.service.starts == ["a"])
        #expect(!coordinator.isPlaying)
    }

    // MARK: - Last played

    @Test func aPodcastEpisodeIsSavedWithItsShowAsAuthor() async throws {
        let show = PodcastMetadata(title: "The Show", author: "Host")
        h.service.state.withLock { $0.metadata["p"] = (.podcast(show), nil) }
        await coordinator.play(itemID: "p", episodeID: "e1")
        #expect(h.lastPlayed.record?.author == "The Show")
    }
}
