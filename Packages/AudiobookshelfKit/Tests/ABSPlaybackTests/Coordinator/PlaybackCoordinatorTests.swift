import ABSCore
import ABSData
import Foundation
import Observation
import Synchronization
import Testing

@testable import ABSAPI
@testable import ABSPlayback

@MainActor
final class EventLog {
    var events: [PlaybackCoordinatorEvent] = []
    var count: Int { events.count }

    func since(_ start: Int) -> [PlaybackCoordinatorEvent] { Array(events[start...]) }
}

/// One coordinator with fakes for every dependency.
@MainActor
struct CoordinatorHarness {
    let connectionID: UUID
    let clock = TestClock()
    let engine = CoordinatorTestEngine()
    let service: StubSessionService
    let settings = StubPlaybackSettings()
    let policy = StubStreamingPolicy()
    let lastPlayed: InMemoryLastPlayedStore
    let progressStore: LocalProgressStore
    let sleep = TestSleep()
    /// Recovery's backoff; it never ends unless a test makes it.
    let recoverySleep = TestSleep()
    let coordinator: PlaybackCoordinator
    let events = EventLog()

    init(
        lastPlayed: InMemoryLastPlayedStore = InMemoryLastPlayedStore(), progressStore: LocalProgressStore? = nil,
        connectionID: UUID = UUID(), progressReader: (any LocalProgressReading)? = nil,
        backgroundActivity: any BackgroundActivity = NoBackgroundActivity()
    ) throws {
        self.connectionID = connectionID
        service = StubSessionService(serverConnectionID: connectionID)
        self.lastPlayed = lastPlayed
        self.progressStore =
            try progressStore ?? LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
        let clock = clock
        let sleep = sleep
        let recoverySleep = recoverySleep
        coordinator = PlaybackCoordinator(
            engine: engine, sessions: service, progressStore: progressReader ?? self.progressStore,
            settings: settings, policy: policy,
            lastPlayedStore: lastPlayed, now: { clock.now }, sleep: { await sleep.sleep($0) },
            backgroundActivity: backgroundActivity, recoveryWait: { await recoverySleep.sleep($0) })
        let events = events
        _ = coordinator.addObserver { events.events.append($0) }
    }

    func key(_ itemID: String) -> MediaKey {
        MediaKey(serverConnectionID: connectionID, libraryItemId: itemID)
    }

    func setServerProgress(_ itemID: String, time: Double, updated: Date, finished: Bool = false) {
        service.state.withLock {
            $0.serverTime[itemID] = time
            $0.progress[itemID] = MediaProgress(
                id: "p-\(itemID)", libraryItemId: itemID, duration: 3600, currentTime: time, isFinished: finished,
                lastUpdate: Int(updated.timeIntervalSince1970 * 1000))
        }
    }

    func setLocalProgress(_ itemID: String, time: Double, updated: Date) async throws {
        try await progressStore.recordEdit(
            ProgressEdit(audio: .init(currentTime: time, duration: 3600, progress: time / 3600)), for: key(itemID),
            now: updated)
    }

    func record(_ itemID: String, position: Double, age: TimeInterval) -> LastPlayedRecord {
        LastPlayedRecord(
            serverConnectionID: connectionID, libraryItemID: itemID, episodeID: nil, position: position,
            duration: 3600, timestamp: clock.ago(age), title: "Saved \(itemID)")
    }
}

/// Yields until `condition` holds (a suspended task reached a gate); records an issue if it never does.
@MainActor
func yieldUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<1000 {
        if condition() { return }
        await Task.yield()
    }
    if !condition() { Issue.record("Condition never became true", sourceLocation: sourceLocation) }
}

@MainActor
struct PlaybackCoordinatorTests {
    let h: CoordinatorHarness
    var coordinator: PlaybackCoordinator { h.coordinator }
    var engine: CoordinatorTestEngine { h.engine }
    var service: StubSessionService { h.service }

    init() throws {
        h = try CoordinatorHarness()
    }

    // MARK: - Start and resume

    @Test func playStartsSessionAtNewestProgressWithRewindAndSavedRate() async throws {
        h.settings.playbackRate = 1.5
        h.setServerProgress("A", time: 300, updated: h.clock.ago(3600))
        try await h.setLocalProgress("A", time: 500, updated: h.clock.ago(120))

        await coordinator.play(itemID: "A")

        // Local is newer; 2 min since then rewinds 10 s.
        #expect(engine.loads.map(\.time) == [490])
        #expect(engine.defaultRate == 1.5)
        #expect(coordinator.rate == 1.5)
        #expect(coordinator.phase == .loaded)
        #expect(coordinator.isPlaying)
        #expect(coordinator.mediaKey == h.key("A"))
        #expect(coordinator.session?.id == "A-1")
        #expect(coordinator.currentTime == 490)
        #expect(coordinator.duration == 3600)
        #expect(coordinator.chapterIndex == 0)
        #expect(coordinator.chapterElapsed == 490)
        #expect(coordinator.chapterRemaining == 510)
        let source = try #require(engine.loads.first?.source)
        #expect(source.trackURLs.count == 2)
        #expect(source.trackMIMETypes == ["audio/mpeg", "audio/mpeg"])
        #expect(source.seekTolerance == 0)
        #expect(source.networkAccess == NetworkAccess(policy: .always))
        #expect(
            h.events.events == [
                .itemChanged(h.key("A")), .sessionStarted(sessionID: "A-1", key: h.key("A")),
                .loaded(time: 490), .didSeek(time: 490), .playbackStarted,
            ])
        let saved = try #require(h.lastPlayed.record)
        #expect(saved.position == 490)
        #expect(saved.title == "Title A")
        #expect(saved.author == "Author")
        #expect(saved.coverPath == "/covers/A.jpg")
        #expect(saved.chapterTitle == "One")
        #expect(!saved.isFinished)
    }

    @Test func newerServerProgressWinsWithLongPauseRewind() async throws {
        h.setServerProgress("A", time: 800, updated: h.clock.ago(2 * 3600))
        try await h.setLocalProgress("A", time: 500, updated: h.clock.ago(3 * 3600))

        await coordinator.play(itemID: "A")

        #expect(engine.loads.map(\.time) == [770])
    }

    @Test func ebookEditDoesNotMakeLocalAudioProgressNewer() async throws {
        h.setServerProgress("A", time: 800, updated: h.clock.ago(3600))
        try await h.setLocalProgress("A", time: 500, updated: h.clock.ago(3 * 3600))
        try await h.progressStore.recordEdit(
            ProgressEdit(ebook: .init(location: "epubcfi(/6/2)", progress: 0.5)), for: h.key("A"),
            now: h.clock.ago(60))

        await coordinator.play(itemID: "A")

        #expect(engine.loads.map(\.time) == [770])
    }

    @Test func failedServerProgressLetsLocalProgressWin() async throws {
        service.state.withLock {
            $0.serverTime["A"] = 800
            $0.progressError = .network(.notConnectedToInternet)
            // The session's own date is its creation time; it must not count.
            $0.sessionUpdatedAt = h.clock.now
        }
        try await h.setLocalProgress("A", time: 500, updated: h.clock.ago(3600))

        await coordinator.play(itemID: "A")
        #expect(engine.loads.map(\.time) == [470])

        // With nothing else, the session's position is used, without rewind.
        service.state.withLock { $0.serverTime["B"] = 800 }
        await coordinator.play(itemID: "B")
        #expect(engine.loads.map(\.time) == [470, 800])
    }

    @Test func explicitStartTimeAndDisabledAutoRewindSkipRewind() async throws {
        h.setServerProgress("A", time: 800, updated: h.clock.ago(3600))
        await coordinator.play(itemID: "A", startTime: 1234)
        #expect(engine.loads.last?.time == 1234)

        h.settings.disableAutoRewind = true
        await coordinator.play(itemID: "B")
        h.lastPlayed.clear()
        await coordinator.play(itemID: "A")
        #expect(engine.loads.last?.time == 800)
    }

    @Test func finishedServerItemStartsFromBeginning() async throws {
        h.setServerProgress("A", time: 3600, updated: h.clock.ago(60), finished: true)
        await coordinator.play(itemID: "A")
        #expect(engine.loads.map(\.time) == [0])
    }

    @Test(arguments: [false, true])
    func playingAgainAfterTheEndRestartsFromZero(serverFinished: Bool) async throws {
        h.setServerProgress("A", time: 3000, updated: h.clock.ago(3600), finished: serverFinished)
        await coordinator.play(itemID: "A", startTime: 3500)
        engine.finish()
        #expect(h.lastPlayed.record?.isFinished == true)
        #expect(h.events.events.last == .ended)

        await coordinator.play(itemID: "A")

        #expect(engine.seeks == [0])
        #expect(coordinator.currentTime == 0)
        #expect(coordinator.isPlaying)
        #expect(engine.loads.count == 1)
        #expect(h.lastPlayed.record?.isFinished == false)
    }

    @Test func finishedRecordRestartsFromZeroAfterRelaunch() async throws {
        h.setServerProgress("A", time: 3000, updated: h.clock.ago(3600))
        try await h.setLocalProgress("A", time: 3000, updated: h.clock.ago(3600))
        await coordinator.play(itemID: "A", startTime: 3500)
        engine.finish()

        let relaunched = try CoordinatorHarness(
            lastPlayed: h.lastPlayed, progressStore: h.progressStore, connectionID: h.connectionID)
        relaunched.setServerProgress("A", time: 3000, updated: h.clock.ago(3600))
        #expect(relaunched.coordinator.restoreLastPlayed())
        #expect(relaunched.coordinator.currentTime == 3600)
        await relaunched.coordinator.resume()

        #expect(relaunched.engine.loads.map(\.time) == [0])
    }

    @Test func resumeAfterPauseRewindsForPauseLength() async throws {
        await coordinator.play(itemID: "A", startTime: 1000)
        coordinator.pause()
        #expect(!coordinator.isPlaying)
        #expect(h.events.events.last == .paused(time: 1000))
        h.clock.advance(by: 6 * 60)

        await coordinator.resume()

        #expect(engine.seeks == [980])
        #expect(coordinator.isPlaying)
        #expect(Array(h.events.events.suffix(2)) == [.didSeek(time: 980), .playbackStarted])
        #expect(engine.loads.count == 1)
    }

    @Test func resumeAsksWillResumeBeforeSeekingAndReportsLanding() async throws {
        await coordinator.play(itemID: "A", startTime: 1000)
        coordinator.pause()
        var seeksWhenAsked: [Double]?
        coordinator.willResume = { [engine] in
            seeksWhenAsked = engine.seeks
            return 30
        }

        await coordinator.resume()

        #expect(seeksWhenAsked == [])
        #expect(engine.seeks == [970])
        #expect(Array(h.events.events.suffix(2)) == [.didSeek(time: 970), .playbackStarted])
    }

    @Test func pauseDuringResumeSeekCancelsPlay() async throws {
        await coordinator.play(itemID: "A", startTime: 1000)
        coordinator.pause()
        h.clock.advance(by: 120)
        let gate = Gate()
        engine.seekGates = [gate]
        let start = h.events.count

        let resume = Task { await coordinator.resume() }
        await yieldUntil { engine.seeks.count == 1 }
        coordinator.pause()
        gate.open()
        await resume.value

        #expect(!coordinator.isPlaying)
        #expect(!h.events.since(start).contains(.playbackStarted))
    }

    @Test func secondResumeWhileOneIsInFlightIsIgnored() async throws {
        await coordinator.play(itemID: "A", startTime: 1000)
        coordinator.pause()
        h.clock.advance(by: 120)
        var asked = 0
        coordinator.willResume = {
            asked += 1
            return 0
        }
        let gate = Gate()
        engine.seekGates = [gate]
        let start = h.events.count

        let first = Task { await coordinator.resume() }
        await yieldUntil { engine.seeks.count == 1 }
        await coordinator.resume()
        gate.open()
        await first.value

        #expect(asked == 1)
        #expect(engine.seeks.count == 1)
        #expect(h.events.since(start).filter { $0 == .playbackStarted }.count == 1)
        #expect(coordinator.isPlaying)
    }

    @Test(arguments: [false, true])
    func pauseOrResumeDuringSeekAfterLoadTakesOver(resumes: Bool) async throws {
        let loadGate = Gate()
        let seekGate = Gate()
        engine.loadGates = [loadGate]
        engine.seekGates = [seekGate]
        let play = Task { await coordinator.play(itemID: "A") }
        await yieldUntil { engine.loads.count == 1 }
        #expect(await coordinator.seek(to: 2000) == nil)
        loadGate.open()
        await yieldUntil { engine.seeks.count == 1 }

        if resumes { await coordinator.resume() } else { coordinator.pause() }
        seekGate.open()
        await play.value

        #expect(coordinator.isPlaying == resumes)
        #expect(h.events.events.filter { $0 == .playbackStarted }.count == (resumes ? 1 : 0))
    }

    @Test func rateChangedInSettingsIsAppliedOnResume() async throws {
        await coordinator.play(itemID: "A")
        coordinator.pause()
        h.settings.playbackRate = 1.75

        await coordinator.resume()

        #expect(engine.defaultRate == 1.75)
    }

    @Test func nearTheEndButNotEndedResumesInPlace() async throws {
        await coordinator.play(itemID: "A", startTime: 3599.5)
        coordinator.pause()

        await coordinator.resume()

        #expect(engine.seeks.isEmpty)
        #expect(coordinator.currentTime == 3599.5)
        #expect(coordinator.isPlaying)
    }

    @Test func playSameItemWithStartTimeWhilePlayingOnlySeeks() async throws {
        await coordinator.play(itemID: "A")
        var asked = 0
        coordinator.willResume = {
            asked += 1
            return 0
        }
        let start = h.events.count

        await coordinator.play(itemID: "A", startTime: 100)

        #expect(engine.seeks == [100])
        #expect(asked == 0)
        #expect(h.events.since(start) == [.didSeek(time: 100)])
        #expect(coordinator.isPlaying)
    }

    @Test func playSameItemWithStartTimeSeeksInSameSession() async throws {
        await coordinator.play(itemID: "A")
        await coordinator.play(itemID: "A", startTime: 2000)

        #expect(service.starts == ["A"])
        #expect(engine.seeks == [2000])
        #expect(coordinator.currentTime == 2000)
        #expect(coordinator.isPlaying)
        #expect(service.closes.isEmpty)
    }

    @Test func startTimeOrSeekWhileStartingIsAppliedOnLoad() async throws {
        let gate = Gate()
        engine.loadGates = [gate]
        let first = Task { await coordinator.play(itemID: "A") }
        await yieldUntil { engine.loads.count == 1 }
        await coordinator.play(itemID: "A", startTime: 2500)
        #expect(await coordinator.seek(to: 2400) == nil)
        gate.open()
        await first.value

        #expect(service.starts == ["A"])
        #expect(coordinator.currentTime == 2400)
        #expect(coordinator.isPlaying)
        #expect(h.events.events.contains(.loaded(time: 2400)))
    }

    @Test func seekReturnsLandingAndSetRateSaves() async throws {
        await coordinator.play(itemID: "A")
        #expect(await coordinator.seek(to: 5000) == 3600)
        #expect(h.events.events.last == .didSeek(time: 3600))

        coordinator.setRate(2)
        #expect(h.settings.playbackRate == 2)
        #expect(coordinator.rate == 2)
        #expect(engine.defaultRate == 2)
        coordinator.setRate(-1)
        #expect(coordinator.rate == 2)
    }

    // MARK: - Cellular policy

    @Test func deniedStreamingPolicyBlocksWithoutSession() async {
        h.policy.decision = .denied(.cellular)

        await coordinator.play(itemID: "A")

        #expect(coordinator.error == .streamingNotAllowed(.cellular, key: h.key("A")))
        #expect(service.starts.isEmpty)
        #expect(engine.loads.isEmpty)
        #expect(coordinator.phase == .idle)
        #expect(h.events.events == [.failed(.streamingNotAllowed(.cellular, key: h.key("A")))])

        await coordinator.play(itemID: "A", allowingMeteredNetwork: true)
        #expect(service.starts.isEmpty)
    }

    @Test func askPolicyNeedsConfirmationThenPlays() async {
        h.policy.decision = .askUser(.lowDataMode)

        await coordinator.play(itemID: "A")
        #expect(coordinator.error == .streamingNeedsConfirmation(.lowDataMode, key: h.key("A")))
        #expect(service.starts.isEmpty)

        await coordinator.play(itemID: "A", allowingMeteredNetwork: true)
        #expect(coordinator.error == nil)
        #expect(service.starts == ["A"])
        #expect(coordinator.isPlaying)
    }

    @Test func blockedPolicyLeavesCurrentItemPlaying() async {
        await coordinator.play(itemID: "A")
        h.policy.decision = .askUser(.cellular)

        await coordinator.play(itemID: "B")
        await coordinator.waitForPendingCloses()

        #expect(coordinator.mediaKey == h.key("A"))
        #expect(coordinator.isPlaying)
        #expect(coordinator.session?.id == "A-1")
        #expect(service.closes.isEmpty)
        #expect(service.starts == ["A"])
        #expect(coordinator.error == .streamingNeedsConfirmation(.cellular, key: h.key("B")))
        #expect(h.events.events.last == .failed(.streamingNeedsConfirmation(.cellular, key: h.key("B"))))
    }

    @Test func blockedPolicyDoesNotInterruptCurrentResumeOrSeek() async throws {
        await coordinator.play(itemID: "A", startTime: 1000)
        coordinator.pause()
        h.clock.advance(by: 120)
        h.policy.decision = .askUser(.cellular)
        let resumeGate = Gate()
        engine.seekGates = [resumeGate]
        let start = h.events.count

        let resume = Task { await coordinator.resume() }
        await yieldUntil { engine.seeks.count == 1 }
        await coordinator.play(itemID: "B")
        resumeGate.open()
        await resume.value

        #expect(coordinator.isPlaying)
        #expect(h.events.since(start).contains(.didSeek(time: 990)))
        #expect(h.events.since(start).contains(.playbackStarted))

        let seekGate = Gate()
        engine.seekGates = [seekGate]
        let seek = Task { await coordinator.seek(to: 2000) }
        await yieldUntil { engine.seeks.count == 2 }
        await coordinator.play(itemID: "B")
        seekGate.open()
        #expect(await seek.value == 2000)
        #expect(h.events.events.last == .didSeek(time: 2000))
        #expect(service.starts == ["A"])
    }

    @Test func stopWhilePolicyCheckIsPendingDiscardsThePlay() async {
        let gate = Gate()
        h.policy.gate = gate
        let play = Task { await coordinator.play(itemID: "A") }
        await yieldUntil { h.policy.checks == 1 }
        #expect(coordinator.pendingPlayKey == h.key("A"))
        #expect(coordinator.phase == .idle)

        coordinator.stop()
        #expect(coordinator.pendingPlayKey == nil)
        gate.open()
        await play.value

        #expect(coordinator.pendingPlayKey == nil)
        #expect(coordinator.phase == .idle)
        #expect(coordinator.mediaKey == nil)
        #expect(service.starts.isEmpty)
        #expect(engine.stopCount == 0)
        #expect(h.events.events.isEmpty)
    }

    @Test func pendingPlayKeyClearsWhenThePlayCommitsOrIsBlocked() async {
        await coordinator.play(itemID: "A")
        #expect(coordinator.pendingPlayKey == nil)
        h.policy.decision = .denied(.cellular)
        await coordinator.play(itemID: "B")
        #expect(coordinator.pendingPlayKey == nil)
    }

    @Test func stalePolicyDecisionIsDiscarded() async {
        h.policy.decision = .denied(.cellular)
        let gate = Gate()
        h.policy.gate = gate
        let first = Task { await coordinator.play(itemID: "A") }
        await yieldUntil { h.policy.checks == 1 }
        h.policy.decision = .allowed

        await coordinator.play(itemID: "B")
        gate.open()
        await first.value

        #expect(coordinator.error == nil)
        #expect(coordinator.mediaKey == h.key("B"))
        #expect(coordinator.isPlaying)
        #expect(service.starts == ["B"])
    }

    // MARK: - Closing

    @Test func switchingItemsClosesPreviousSessionOnce() async {
        await coordinator.play(itemID: "A")
        await coordinator.play(itemID: "B")
        await coordinator.waitForPendingCloses()

        #expect(service.closes == ["A-1"])
        #expect(coordinator.mediaKey == h.key("B"))
        #expect(coordinator.isPlaying)
        #expect(h.events.events.contains(.sessionWillClose(closingA)))

        coordinator.stop()
        await coordinator.waitForPendingCloses()
        #expect(service.closes == ["A-1", "B-2"])
        #expect(coordinator.phase == .idle)
        #expect(h.lastPlayed.record == nil)
        #expect(h.events.events.last == .itemChanged(nil))
    }

    @Test func eachSessionOfTheSameItemIsClosed() async {
        await coordinator.play(itemID: "A")
        await coordinator.play(itemID: "B")
        await coordinator.play(itemID: "A")
        coordinator.stop()
        await coordinator.waitForPendingCloses()

        #expect(service.closes == ["A-1", "B-2", "A-3"])
    }

    @Test func nextPlayWaitsForPreviousClose() async {
        await coordinator.play(itemID: "A")
        let gate = Gate()
        service.state.withLock { $0.closeGates["A-1"] = gate }

        let next = Task { await coordinator.play(itemID: "B") }
        await yieldUntil { service.closes == ["A-1"] }
        gate.open()
        await next.value

        // The log order is the proof: B starts only after A's close returned.
        #expect(service.log == ["start A", "close A-1", "close A-1 done", "start B"])
        #expect(coordinator.isPlaying)
    }

    @Test func playDuringWaitForCloseSupersedesIt() async {
        await coordinator.play(itemID: "A")
        let gate = Gate()
        service.state.withLock { $0.closeGates["A-1"] = gate }

        let playB = Task { await coordinator.play(itemID: "B") }
        await yieldUntil { service.closes == ["A-1"] }
        let playC = Task { await coordinator.play(itemID: "C") }
        await yieldUntil { coordinator.mediaKey == h.key("C") }
        gate.open()
        await playB.value
        await playC.value
        await coordinator.waitForPendingCloses()

        // B never starts; C waited for A's close too.
        #expect(service.log == ["start A", "close A-1", "close A-1 done", "start C"])
        #expect(coordinator.mediaKey == h.key("C"))
        #expect(coordinator.session?.id == "C-2")
        #expect(coordinator.isPlaying)
    }

    @Test func slowCloseTimesOutWithoutBlocking() async {
        await coordinator.play(itemID: "A")
        let gate = Gate()
        service.state.withLock { $0.closeGates["A-1"] = gate }
        h.sleep.elapsesImmediately = true

        await coordinator.play(itemID: "B")

        #expect(service.starts == ["A", "B"])
        #expect(coordinator.isPlaying)
        gate.open()
        await coordinator.waitForPendingCloses()
    }

    @Test func switchingItemsKeepsTheAudioSessionUntilStop() async {
        await coordinator.play(itemID: "A")
        await coordinator.play(itemID: "B")
        await coordinator.play(itemID: "A")

        #expect(engine.unloadCount == 2)
        #expect(engine.stopCount == 0)
        coordinator.stop()
        #expect(engine.stopCount == 1)
        await coordinator.waitForPendingCloses()
    }

    @Test func aFailedSwitchReleasesTheKeptAudioSession() async {
        await coordinator.play(itemID: "A")
        service.state.withLock { $0.startError = .forbidden(message: nil) }

        await coordinator.play(itemID: "B")

        #expect(engine.unloadCount == 1)
        #expect(engine.stopCount == 1)
        // Released once: a later stop has nothing left to release.
        coordinator.stop()
        #expect(engine.stopCount == 1)
        await coordinator.waitForPendingCloses()
    }

    @Test func aSwitchCancelledDuringTheCloseWaitReleasesTheKeptAudioSession() async {
        await coordinator.play(itemID: "A")
        let gate = Gate()
        service.state.withLock { $0.closeGates["A-1"] = gate }
        h.sleep.isManual = true

        let playB = Task { await coordinator.play(itemID: "B") }
        await yieldUntil { h.sleep.waitingCount == 1 }
        playB.cancel()
        h.sleep.fireOldest()
        await playB.value

        #expect(service.starts == ["A"])
        #expect(coordinator.error == nil)
        #expect(engine.unloadCount == 1)
        #expect(engine.stopCount == 1)
        gate.open()
        await coordinator.waitForPendingCloses()
    }

    @Test func aSwitchCancelledDuringStreamResolutionReleasesTheKeptAudioSession() async {
        await coordinator.play(itemID: "A")
        service.state.withLock { $0.resolveError = CancellationError() }

        await coordinator.play(itemID: "B")

        #expect(coordinator.error == nil)
        #expect(coordinator.phase == .unloaded)
        #expect(engine.unloadCount == 1)
        #expect(engine.stopCount == 1)
        await coordinator.waitForPendingCloses()
    }

    @Test func eachCloseIsWaitedForOnlyUntilItsOwnTimeLimit() async {
        await coordinator.play(itemID: "A")
        let gateA = Gate()
        service.state.withLock { $0.closeGates["A-1"] = gateA }
        coordinator.stop()
        await yieldUntil { service.closes == ["A-1"] }
        h.clock.advance(by: 1.5)
        h.sleep.elapsesImmediately = true
        await coordinator.play(itemID: "B")
        h.sleep.elapsesImmediately = false
        h.sleep.isManual = true
        let gateB = Gate()
        service.state.withLock { $0.closeGates["B-2"] = gateB }

        // A's close has 0.5 s left and B's a full 2 s; B's finishing ends its own wait only.
        let playC = Task { await coordinator.play(itemID: "C") }
        await yieldUntil { h.sleep.waitingCount == 2 }
        gateB.open()
        await yieldUntil { h.sleep.waitingCount == 1 }
        h.sleep.fireOldest()
        await playC.value

        #expect(Array(h.sleep.durations.suffix(2)).sorted() == [.seconds(0.5), PlaybackCoordinator.closeWaitTimeout])
        #expect(service.starts == ["A", "B", "C"])
        #expect(!service.log.contains("close A-1 done"))
        gateA.open()
        await coordinator.waitForPendingCloses()
    }

    @Test func aHangingCloseDelaysOnlyThePlayRightAfterIt() async {
        await coordinator.play(itemID: "A")
        let gate = Gate()
        service.state.withLock { $0.closeGates["A-1"] = gate }
        h.sleep.isManual = true

        let playB = Task { await coordinator.play(itemID: "B") }
        await yieldUntil { h.sleep.waitingCount == 1 }
        #expect(h.sleep.durations == [PlaybackCoordinator.closeWaitTimeout])
        h.clock.advance(by: 2)
        h.sleep.fireOldest()
        await playB.value

        // A's close still hangs, but it has had its 2 s: C waits at most for B's close.
        let playC = Task { await coordinator.play(itemID: "C") }
        await yieldUntil { service.starts == ["A", "B", "C"] }
        #expect(!service.log.contains("close A-1 done"))

        gate.open()
        while h.sleep.waitingCount > 0 { h.sleep.fireOldest() }
        await playC.value
        await coordinator.waitForPendingCloses()
    }

    @Test func theCloseWaitCountsFromWhenTheCloseWasSent() async {
        await coordinator.play(itemID: "A")
        let gate = Gate()
        service.state.withLock { $0.closeGates["A-1"] = gate }
        coordinator.stop()
        await yieldUntil { service.closes == ["A-1"] }
        h.clock.advance(by: 1.5)
        h.sleep.isManual = true

        let playB = Task { await coordinator.play(itemID: "B") }
        await yieldUntil { h.sleep.waitingCount == 1 }
        #expect(h.sleep.durations == [.seconds(0.5)])

        h.sleep.fireOldest()
        await playB.value
        #expect(service.starts == ["A", "B"])
        gate.open()
        await coordinator.waitForPendingCloses()
    }

    @Test func finalCloseReportIsAskedOnlyForLoadedSessions() async {
        var closing: [ClosingSession] = []
        coordinator.finalCloseReport = {
            closing.append($0)
            return PlaybackSyncReport(currentTime: $0.currentTime, timeListened: 0, duration: $0.duration)
                .map { PlaybackCloseHandoff(report: $0, position: PlaybackCloseResult()) }
        }
        await coordinator.play(itemID: "A", startTime: 42)
        coordinator.stop()
        #expect(closing.map(\.currentTime) == [42])
        #expect(closing.map(\.reason) == [.stopped])

        let gate = Gate()
        engine.loadGates = [gate]
        let first = Task { await coordinator.play(itemID: "B", startTime: 77) }
        await yieldUntil { engine.loads.count == 2 }
        await coordinator.play(itemID: "C")
        gate.open()
        await first.value

        #expect(closing.count == 1)
        #expect(
            h.events.events.contains(
                .sessionWillClose(
                    ClosingSession(
                        sessionID: "B-2", key: h.key("B"), currentTime: 77, duration: 3600, wasLoaded: false,
                        reason: .itemChanged))))
    }

    @Test func failedCloseDoesNotBlockNextPlay() async {
        service.state.withLock { $0.closeError = .network(.notConnectedToInternet) }
        await coordinator.play(itemID: "A")
        await coordinator.play(itemID: "B")
        await coordinator.waitForPendingCloses()

        #expect(service.closes == ["A-1"])
        #expect(coordinator.mediaKey == h.key("B"))
        #expect(coordinator.isPlaying)
        #expect(coordinator.error == nil)
    }

    @Test func retryingAFailedStartUsesTheRestartedReason() async {
        let gate = Gate()
        engine.loadGates = [gate]
        let first = Task { await coordinator.play(itemID: "A") }
        await yieldUntil { engine.loads.count == 1 }
        engine.loadError = .emptyTimeline
        gate.open()
        await first.value
        #expect(coordinator.error == .engine(.emptyTimeline))
        #expect(
            h.events.events.contains { event in
                if case .sessionWillClose(let closing) = event { return closing.reason == .loadFailed }
                return false
            })
        engine.loadError = nil

        await coordinator.resume()

        #expect(service.starts == ["A", "A"])
        #expect(coordinator.isPlaying)
        #expect(coordinator.session?.id == "A-2")
    }

    // MARK: - Races

    @Test func lateSessionStartIsClosedAndDiscarded() async {
        let gate = Gate()
        service.state.withLock { $0.startGates["A"] = gate }
        let first = Task { await coordinator.play(itemID: "A") }
        await yieldUntil { service.starts == ["A"] }

        // B's start takes its turn after A's returns, so it can't finish before the gate opens.
        let second = Task { await coordinator.play(itemID: "B") }
        await yieldUntil { coordinator.mediaKey == h.key("B") }
        gate.open()
        await first.value
        await second.value
        await coordinator.waitForPendingCloses()

        #expect(coordinator.mediaKey == h.key("B"))
        #expect(coordinator.session?.id == "B-2")
        #expect(coordinator.isPlaying)
        #expect(engine.loads.count == 1)
        #expect(service.closes == ["A-1"])
    }

    @Test func lateEngineLoadIsSupersededAndSessionClosedOnce() async {
        let gate = Gate()
        engine.loadGates = [gate]
        let first = Task { await coordinator.play(itemID: "A") }
        await yieldUntil { engine.loads.count == 1 }
        #expect(coordinator.isBuffering)

        await coordinator.play(itemID: "B")
        gate.open()
        await first.value
        await coordinator.waitForPendingCloses()

        #expect(coordinator.mediaKey == h.key("B"))
        #expect(coordinator.phase == .loaded)
        #expect(coordinator.isPlaying)
        #expect(service.closes == ["A-1"])
    }

    @Test func stopDuringEngineLoad() async {
        let gate = Gate()
        engine.loadGates = [gate]
        let first = Task { await coordinator.play(itemID: "A") }
        await yieldUntil { engine.loads.count == 1 }

        coordinator.stop()
        gate.open()
        await first.value
        await coordinator.waitForPendingCloses()

        #expect(service.closes == ["A-1"])
        #expect(coordinator.phase == .idle)
        #expect(coordinator.mediaKey == nil)
        #expect(h.lastPlayed.record == nil)
    }

    @Test func stopDuringSessionStart() async {
        let gate = Gate()
        service.state.withLock { $0.startGates["A"] = gate }
        let first = Task { await coordinator.play(itemID: "A") }
        await yieldUntil { service.starts == ["A"] }

        coordinator.stop()
        gate.open()
        await first.value
        await coordinator.waitForPendingCloses()

        #expect(service.closes == ["A-1"])
        #expect(coordinator.phase == .idle)
        #expect(engine.loads.isEmpty)
        #expect(h.events.events.last == .itemChanged(nil))
    }

    /// Play intent while starting is only `playWhenLoaded`; a pause must still invalidate
    /// observers of `isPlaybackRequested`, or a play/pause button keeps showing pause.
    @Test func pauseWhileStartingInvalidatesPlayIntent() async {
        let gate = Gate()
        service.state.withLock { $0.startGates["A"] = gate }
        let play = Task { await coordinator.play(itemID: "A") }
        await yieldUntil { service.starts == ["A"] }
        #expect(coordinator.phase == .starting)
        #expect(coordinator.isPlaybackRequested)

        let changes = Mutex(0)
        withObservationTracking {
            _ = coordinator.isPlaybackRequested
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        coordinator.pause()
        #expect(changes.withLock { $0 } == 1)
        #expect(!coordinator.isPlaybackRequested)

        gate.open()
        await play.value
        #expect(coordinator.phase == .loaded)
        #expect(!coordinator.isPlaybackRequested)
    }

    @Test func pauseWhileStartingLoadsPaused() async {
        let gate = Gate()
        engine.loadGates = [gate]
        let first = Task { await coordinator.play(itemID: "A") }
        await yieldUntil { engine.loads.count == 1 }
        coordinator.pause()
        gate.open()
        await first.value

        #expect(coordinator.phase == .loaded)
        #expect(!coordinator.isPlaying)
    }

    @Test func observerMayStopFromAHandler() async {
        await coordinator.play(itemID: "A")
        let coordinator = coordinator
        _ = coordinator.addObserver { [weak coordinator] event in
            if case .sessionWillClose = event { coordinator?.stop() }
        }

        await coordinator.play(itemID: "B")
        await coordinator.waitForPendingCloses()

        #expect(coordinator.phase == .idle)
        #expect(coordinator.mediaKey == nil)
        #expect(service.starts == ["A"])
        #expect(service.closes == ["A-1"])
        #expect(Array(h.events.events.suffix(2)) == [.sessionWillClose(closingA), .itemChanged(nil)])
    }

    private var closingA: ClosingSession {
        ClosingSession(
            sessionID: "A-1", key: h.key("A"), currentTime: 0, duration: 3600, wasLoaded: true, reason: .itemChanged)
    }

    // MARK: - Errors

    @Test func sessionStartFailureIsSurfaced() async {
        service.state.withLock { $0.startError = .forbidden(message: nil) }
        await coordinator.play(itemID: "A")
        #expect(coordinator.error == .sessionStartFailed(.forbidden(message: nil)))
        #expect(coordinator.phase == .unloaded)
        #expect(coordinator.mediaKey == h.key("A"))
    }

    @Test func streamResolutionFailureIsSurfacedAndClosesTheSession() async {
        service.state.withLock { $0.resolveError = StreamResolutionError.missingAccessToken }
        await coordinator.play(itemID: "A")
        await coordinator.waitForPendingCloses()

        #expect(coordinator.error == .streamUnavailable(.missingAccessToken))
        #expect(coordinator.phase == .unloaded)
        #expect(service.closes == ["A-1"])
        #expect(h.events.events.last == .failed(.streamUnavailable(.missingAccessToken)))
    }

    @Test func cancelledStreamResolutionIsNotAFailure() async {
        service.state.withLock { $0.resolveError = CancellationError() }
        await coordinator.play(itemID: "A")
        await coordinator.waitForPendingCloses()

        #expect(coordinator.error == nil)
        #expect(coordinator.phase == .unloaded)
        #expect(coordinator.mediaKey == h.key("A"))
        #expect(service.closes == ["A-1"])
        #expect(engine.loads.isEmpty)
        #expect(h.events.events == [.itemChanged(h.key("A"))])

        // The abandoned start doesn't leave the item stuck: playing again starts a new session.
        service.state.withLock { $0.resolveError = nil }
        await coordinator.play(itemID: "A")
        #expect(coordinator.phase == .loaded)
        #expect(coordinator.error == nil)
        #expect(service.starts == ["A", "A"])
    }

    @Test func engineLoadFailureClosesSessionAndSurfacesPlaybackFailure() async {
        let failure = PlaybackFailure(
            kind: .http(status: 404), domain: "CoreMediaErrorDomain", code: -12938, description: "404")
        engine.loadError = .itemFailed(trackIndex: 0, failure)

        await coordinator.play(itemID: "A")
        await coordinator.waitForPendingCloses()

        #expect(coordinator.error == .playback(failure))
        #expect(coordinator.phase == .unloaded)
        #expect(service.closes == ["A-1"])
    }

    @Test func engineFailureEventIsSurfaced() async {
        await coordinator.play(itemID: "A")
        // Not recoverable (ADR 0007), so recovery surfaces it at once.
        let failure = PlaybackFailure(
            kind: .http(status: 403), domain: "CoreMediaErrorDomain", code: -12660, description: "forbidden")
        engine.onEvent?(.failed(.playerFailed(failure)))

        #expect(coordinator.error == .playback(failure))
        #expect(h.events.events.last == .failed(.playback(failure)))
    }

    // MARK: - Restore

    @Test func restoreIsLazyAndFirstPlayResumesFromRecord() async {
        h.lastPlayed.record = h.record("A", position: 600, age: 10 * 60)
        h.setServerProgress("A", time: 100, updated: h.clock.ago(86_400))

        #expect(coordinator.restoreLastPlayed())

        #expect(coordinator.phase == .unloaded)
        #expect(coordinator.mediaKey == h.key("A"))
        #expect(coordinator.currentTime == 600)
        #expect(coordinator.duration == 3600)
        #expect(coordinator.restoredRecord?.title == "Saved A")
        #expect(!coordinator.isPlaying)
        #expect(service.starts.isEmpty)
        #expect(engine.loads.isEmpty)
        #expect(h.events.events == [.itemChanged(h.key("A"))])

        await coordinator.resume()

        // The record is newest; 10 min since then rewinds 20 s.
        #expect(service.starts == ["A"])
        #expect(engine.loads.map(\.time) == [580])
        #expect(coordinator.isPlaying)
        #expect(coordinator.restoredRecord == nil)
    }

    @Test func seekWhileRestoredStartsExactlyThere() async {
        h.lastPlayed.record = h.record("A", position: 600, age: 3600)
        h.setServerProgress("A", time: 300, updated: h.clock.ago(2 * 3600))
        coordinator.restoreLastPlayed()
        var asked = 0
        coordinator.willResume = {
            asked += 1
            return 30
        }

        #expect(await coordinator.seek(to: 1200) == 1200)
        #expect(coordinator.currentTime == 1200)
        await coordinator.resume()

        // An explicit start: no auto-rewind and no extra rewind.
        #expect(engine.loads.map(\.time) == [1200])
        #expect(engine.seeks.isEmpty)
        #expect(asked == 1)
        #expect(coordinator.isPlaying)
    }

    @Test func seekWhileRestoredYieldsToNewerServerProgress() async {
        h.lastPlayed.record = h.record("A", position: 600, age: 3600)
        h.setServerProgress("A", time: 900, updated: h.clock.ago(10 * 60))
        coordinator.restoreLastPlayed()

        await coordinator.seek(to: 630)
        await coordinator.resume()

        // Another device played it after the record: newest-of wins (900, rewound 20 s).
        #expect(engine.loads.map(\.time) == [880])
    }

    /// This device's own progress reaching the server late, or a different position within the
    /// skew window, doesn't override the seek.
    @Test(arguments: [(600.0, 3599.0), (603.0, 600.0), (900.0, 3550.0)])
    func seekWhileRestoredIgnoresOwnLateProgress(serverTime: Double, age: TimeInterval) async {
        h.lastPlayed.record = h.record("A", position: 600, age: 3600)
        h.setServerProgress("A", time: serverTime, updated: h.clock.ago(age))
        coordinator.restoreLastPlayed()

        await coordinator.seek(to: 1200)
        await coordinator.resume()

        #expect(engine.loads.map(\.time) == [1200])
    }

    @Test(arguments: [false, true])
    func failedStartRetryKeepsSeekWhileRestored(newerServer: Bool) async {
        h.lastPlayed.record = h.record("A", position: 600, age: 3600)
        coordinator.restoreLastPlayed()
        await coordinator.seek(to: 1200)
        service.state.withLock { $0.startError = .network(.notConnectedToInternet) }
        await coordinator.resume()
        #expect(coordinator.phase == .unloaded)

        service.state.withLock { $0.startError = nil }
        if newerServer { h.setServerProgress("A", time: 900, updated: h.clock.ago(10 * 60)) }
        await coordinator.resume()

        #expect(engine.loads.map(\.time) == [newerServer ? 880 : 1200])
    }

    @Test func failedLoadRetryKeepsStartTime() async {
        engine.loadError = .emptyTimeline
        await coordinator.play(itemID: "A", startTime: 1500)
        #expect(coordinator.phase == .unloaded)

        engine.loadError = nil
        await coordinator.resume()

        #expect(engine.loads.map(\.time) == [1500, 1500])
        #expect(coordinator.isPlaying)
    }

    @Test func restoreThenPlayAnotherItem() async {
        h.lastPlayed.record = h.record("A", position: 600, age: 60)
        coordinator.restoreLastPlayed()

        await coordinator.play(itemID: "B")
        await coordinator.waitForPendingCloses()

        #expect(service.starts == ["B"])
        #expect(service.closes.isEmpty)
        #expect(coordinator.mediaKey == h.key("B"))
        #expect(coordinator.restoredRecord == nil)
        #expect(engine.loads.map(\.time) == [0])
        #expect(Array(h.events.events.prefix(2)) == [.itemChanged(h.key("A")), .itemChanged(h.key("B"))])
    }

    @Test func restoreIgnoresOtherConnectionsAndLoadedState() async {
        h.lastPlayed.record = LastPlayedRecord(
            serverConnectionID: UUID(), libraryItemID: "A", episodeID: nil, position: 600, duration: nil,
            timestamp: h.clock.now)
        #expect(!coordinator.restoreLastPlayed())
        #expect(coordinator.phase == .idle)

        await coordinator.play(itemID: "B")
        h.lastPlayed.record?.serverConnectionID = h.connectionID
        #expect(!coordinator.restoreLastPlayed())
        #expect(coordinator.mediaKey == h.key("B"))
    }

    @Test func lastPlayedIsSavedOnPauseAndThrottledTicks() async {
        await coordinator.play(itemID: "A", episodeID: "E", startTime: 100)
        #expect(h.lastPlayed.record?.episodeID == "E")
        engine.onEvent?(.tick(105))
        #expect(h.lastPlayed.record?.position == 100)
        h.clock.advance(by: 20)
        engine.onEvent?(.tick(120))
        #expect(h.lastPlayed.record?.timestamp == h.clock.now)
        coordinator.pause()
        #expect(h.lastPlayed.record?.timestamp == h.clock.now)
        #expect(h.events.events.contains(.tick(time: 105)))
    }
}
