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

    @Test func jumpAfterASeekDuringEngineLoadUsesThePendingTarget() async throws {
        let gate = Gate()
        engine.loadGates = [gate]
        let coordinator = coordinator
        let play = Task { await coordinator.play(itemID: "a") }
        await yieldUntil { engine.loads.count == 1 }
        #expect(engine.loads.last?.time == 0)
        #expect(coordinator.phase == .starting)

        // The resume position is already resolved; hold the engine load, not the session start.
        #expect(await coordinator.seek(to: 1000) == nil)
        #expect(await coordinator.jump(by: -15) == nil)
        #expect(coordinator.currentTime == 985, "Displayed at \(coordinator.currentTime), expected 985")
        gate.open()
        await play.value

        #expect(engine.seeks == [985])
        #expect(coordinator.currentTime == 985, "Landed at \(coordinator.currentTime), expected 985")
        #expect(h.events.events.contains(.loaded(time: 985)))
        #expect(h.events.events.filter { if case .didSeek = $0 { true } else { false } } == [.didSeek(time: 985)])
        #expect(h.lastPlayed.record?.position == 985)
        #expect(coordinator.isPlaying)
    }

    @Test(
        arguments: [(false, false), (true, false), (false, true), (true, true)],
        [
            (4000.0, -15.0, 3585.0), (-100.0, 15.0, 15.0), (Double.nan, 15.0, 15.0),
            (Double.infinity, 15.0, 15.0), (-Double.infinity, 15.0, 15.0),
        ])
    func jumpsDuringEngineLoadNormalizeAbsoluteTargets(
        mode: (supersedingSeek: Bool, failedLoad: Bool), sample: (target: Double, jump: Double, landing: Double)
    ) async throws {
        let gate = Gate()
        engine.loadGates = [gate]
        let coordinator = coordinator
        let play = Task { await coordinator.play(itemID: "a", startTime: mode.supersedingSeek ? nil : sample.target) }
        await yieldUntil { engine.loads.count == 1 }
        #expect(engine.loads.last?.time == (mode.supersedingSeek || sample.target != 4000 ? 0 : 3600))

        if mode.supersedingSeek { await coordinator.seek(to: sample.target) }
        if mode.failedLoad {
            engine.loadError = .emptyTimeline
            gate.open()
            await play.value
            #expect(coordinator.phase == .unloaded)
        }
        await coordinator.jump(by: sample.jump)
        // Invalid jumps must neither replace nor corrupt the finite offset.
        for offset in [Double.nan, Double.infinity, -Double.infinity] {
            #expect(await coordinator.jump(by: offset) == nil)
        }
        #expect(coordinator.currentTime == sample.landing)
        if mode.failedLoad {
            engine.loadError = nil
            await coordinator.resume()
        } else {
            gate.open()
            await play.value
        }

        #expect(engine.seeks == (mode.failedLoad ? [] : [sample.landing]))
        #expect(
            coordinator.currentTime == sample.landing,
            "Landed at \(coordinator.currentTime), expected \(sample.landing)")
        #expect(h.events.events.contains(.loaded(time: sample.landing)))
        #expect(
            h.events.events.filter { if case .didSeek = $0 { true } else { false } }
                == [.didSeek(time: sample.landing)])
        #expect(h.lastPlayed.record?.position == sample.landing)
    }

    @Test(arguments: [(10.0, false), (120.0, false), (120.0, true)])
    func jumpDuringReconciledLoadUsesTheResolvedAnchor(recordAge: TimeInterval, retry: Bool) async throws {
        h.lastPlayed.record = h.record("a", position: 120, age: recordAge)
        h.setServerProgress("a", time: 1000, updated: h.clock.ago(1))
        coordinator.restoreLastPlayed()
        await coordinator.seek(to: 3600)
        let gate = Gate()
        engine.loadGates = [gate]
        let coordinator = coordinator
        let play = Task { await coordinator.resume() }
        await yieldUntil { engine.loads.count == 1 }
        // A 9-second date difference stays inside the skew window; 119 seconds is foreign progress.
        let resolved = recordAge > 60 ? 1000.0 : 3600.0
        #expect(engine.loads.last?.time == resolved)
        #expect(coordinator.currentTime == resolved)

        await coordinator.jump(by: 30)
        let jumped = min(resolved + 30, 3600)
        #expect(coordinator.currentTime == jumped, "Shown at \(coordinator.currentTime), expected \(jumped)")
        if retry { engine.loadError = .emptyTimeline }
        gate.open()
        await play.value

        if retry {
            #expect(coordinator.phase == .unloaded)
            engine.loadError = nil
            // With progress unavailable on retry, retain the resolved start, not the discarded
            // seek to 3600 or the last-played record at 120. Failed starts drop their jump offset.
            h.service.state.withLock {
                $0.progressError = .forbidden(message: nil)
                $0.serverTime["a"] = 0
            }
            await coordinator.resume()
            #expect(engine.loads.map(\.time) == [resolved, resolved])
        }
        let landing = retry ? resolved : jumped
        #expect(coordinator.currentTime == landing, "Landed at \(coordinator.currentTime), expected \(landing)")
        #expect(engine.seeks == (!retry && resolved < 3600 ? [jumped] : []))
        #expect(
            h.events.events.filter { if case .didSeek = $0 { true } else { false } } == [.didSeek(time: landing)])
        #expect(h.lastPlayed.record?.position == landing)
    }

    @Test func jumpsWhileANewItemStartsShowOnlyOnceLoaded() async throws {
        h.setServerProgress("a", time: 500, updated: h.clock.ago(10))
        let (play, gate) = await playHeld("a")

        await coordinator.jump(by: 30)
        // The resume position isn't known yet: no 0:30 that snaps to 8:50.
        #expect(coordinator.currentTime == 0)
        gate.open()
        await play.value

        #expect(engine.loads.last?.time == 500)
        #expect(engine.seeks == [530])
        #expect(coordinator.currentTime == 530)
    }

    @Test func jumpsWhileRestartingStayWithinTheItem() async throws {
        h.lastPlayed.record = h.record("a", position: 3590, age: 3600)
        coordinator.restoreLastPlayed()
        let (play, gate) = await playHeld("a")

        await coordinator.jump(by: 30)
        #expect(coordinator.currentTime == 3600)
        await coordinator.jump(by: -30)
        #expect(coordinator.currentTime == 3570)
        gate.open()
        await play.value

        #expect(engine.loads.last?.time == 3590)
        #expect(engine.seeks == [3570])
        #expect(coordinator.currentTime == 3570)
    }

    @Test(arguments: [false, true])
    func jumpAfterAnInterruptedLoadUsesItsPendingPosition(interruptJump: Bool) async throws {
        h.setServerProgress("a", time: 500, updated: h.clock.ago(10))
        engine.interruptedLoads = 1
        if interruptJump { engine.seekResults = [.interrupted] }
        let (play, gate) = await playHeld("a")
        await coordinator.jump(by: 30)
        gate.open()
        await play.value

        #expect(engine.loads.last?.time == 500)
        #expect(engine.seeks == [530])
        #expect(coordinator.currentTime == 530)
        #expect(h.events.events.contains(.loaded(time: 530)))
        #expect(h.lastPlayed.record?.position == 530)
        if interruptJump {
            #expect(!h.events.events.contains { if case .didSeek = $0 { true } else { false } })
            engine.landPendingSeek()
        }
        engine.onEvent?(.tick(530))
        #expect(h.events.events.filter { if case .didSeek = $0 { true } else { false } } == [.didSeek(time: 530)])
    }

    @Test(arguments: ["completed", "tick", "superseded"])
    func aNewJumpSupersedesTheCatchUpSeekAndReportsOneLanding(landing: String) async throws {
        let service = StubProgressSyncService(serverConnectionID: h.connectionID)
        let clock = h.clock
        let syncer = ProgressSyncer(
            source: coordinator, service: service, store: h.progressStore,
            clock: ProgressSyncClock(now: { clock.now }, uptime: { clock.now.timeIntervalSince1970 }))
        let (play, seekGate) = await playHeldInCatchUpSeek()
        if landing == "superseded" {
            let gate = Gate()
            engine.seekGates = [gate]
            let coordinator = coordinator
            let older = Task { await coordinator.jump(by: 15) }
            await yieldUntil { engine.seeks.last == 45 }
            #expect(await coordinator.jump(by: 15) == 60)
            gate.open()
            #expect(await older.value == nil)
        } else {
            if landing == "tick" { engine.seekResults = [.interrupted] }
            #expect(await coordinator.jump(by: 30) == (landing == "tick" ? nil : 60))
            if landing == "tick" { engine.landPendingSeek() }
        }
        seekGate.open()
        await play.value

        #expect(engine.seeks == (landing == "superseded" ? [30, 45, 60] : [30, 60]))
        #expect(engine.currentTime == 60)
        #expect(coordinator.currentTime == 60)
        let landings = h.events.events.filter {
            if case .loaded = $0 { return true }
            if case .didSeek = $0 { return true }
            return false
        }
        #expect(landings == [.loaded(time: 60), .didSeek(time: 60)])
        #expect(startCount == 1)

        h.clock.advance(by: 1)
        engine.currentTime = 61
        engine.onEvent?(.tick(61))
        await syncer.flush()
        #expect(try await h.progressStore.progress(for: h.key("a"))?.currentTime == 61)
        await coordinator.seek(to: 60)
        await syncer.waitForIdle()
        let stored = try await h.progressStore.progress(for: h.key("a"))
        #expect(stored?.currentTime == 60, "Stored \(stored?.currentTime ?? -1) after seeking back to 60")
        #expect(service.reports.last?.currentTime == 60)
    }

    // MARK: - Play intent

    /// Loads "a" with play requested and the catch-up seek (for a jump while starting) held.
    private func playHeldInCatchUpSeek() async -> (task: Task<Void, Never>, seekGate: Gate) {
        let (play, gate) = await playHeld("a")
        await coordinator.jump(by: 30)
        let seekGate = Gate()
        engine.seekGates = [seekGate]
        gate.open()
        await yieldUntil { engine.seeks == [30] }
        return (play, seekGate)
    }

    @Test func playingTheSameItemDuringTheCatchUpSeekWaitsForIt() async throws {
        let (play, seekGate) = await playHeldInCatchUpSeek()

        await coordinator.play(itemID: "a")
        #expect(coordinator.isPlaybackRequested)
        #expect(!engine.isPlaybackRequested)
        #expect(startCount == 0)
        seekGate.open()
        await play.value

        #expect(coordinator.isPlaying)
        #expect(engine.seeks == [30])
        #expect(startCount == 1)
    }

    @Test func stopDuringTheCatchUpSeekEndsTheLoad() async throws {
        let (play, seekGate) = await playHeldInCatchUpSeek()

        coordinator.stop()
        #expect(coordinator.phase == .idle)
        #expect(!coordinator.isPlaybackRequested)
        seekGate.open()
        await play.value
        #expect(!engine.isPlaybackRequested)
        #expect(startCount == 0)

        // Nothing from the stopped load lingers: a later play of the item plays normally.
        await coordinator.play(itemID: "a")
        #expect(coordinator.isPlaying)
        #expect(startCount == 1)
        coordinator.pause()
        #expect(!coordinator.isPlaybackRequested)
    }

    /// A switch requests play for the new item (it starts playing), so `isPlaybackRequested` follows
    /// it; what must not leak is the old item's pending start.
    @Test func switchingItemsDuringTheCatchUpSeekDropsTheOldStart() async throws {
        let (playA, seekGate) = await playHeldInCatchUpSeek()
        let (playB, gateB) = await playHeld("b")

        #expect(coordinator.mediaKey == h.key("b"))
        coordinator.pause()
        #expect(!coordinator.isPlaybackRequested)
        seekGate.open()
        await playA.value
        #expect(!coordinator.isPlaybackRequested)
        #expect(!engine.isPlaybackRequested)
        #expect(startCount == 0)

        gateB.open()
        await playB.value
        #expect(coordinator.phase == .loaded)
        #expect(!coordinator.isPlaybackRequested)
        #expect(!engine.isPlaybackRequested)
        #expect(startCount == 0)
    }

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
        #expect(!engine.isPlaybackRequested)
        coordinator.pause()
        #expect(!coordinator.isPlaybackRequested)
        seekGate.open()
        await play.value

        #expect(!coordinator.isPlaying)
        #expect(!engine.isPlaybackRequested)
        #expect(startCount == 0)

        await coordinator.resume()
        #expect(coordinator.isPlaying)
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
