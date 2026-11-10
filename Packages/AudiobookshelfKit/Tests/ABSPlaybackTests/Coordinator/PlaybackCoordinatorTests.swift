import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

@MainActor
struct PlaybackCoordinatorTests {
    let connectionID = UUID()
    let clock = TestClock()
    let engine = CoordinatorTestEngine()
    let service: StubSessionService
    let settings = StubPlaybackSettings()
    let policy = StubStreamingPolicy()
    let lastPlayed = InMemoryLastPlayedStore()
    let progressStore: LocalProgressStore
    let coordinator: PlaybackCoordinator
    let events: EventLog

    final class EventLog {
        var events: [PlaybackCoordinatorEvent] = []
    }

    init() throws {
        service = StubSessionService(serverConnectionID: connectionID)
        progressStore = LocalProgressStore(modelContainer: try DataStack(location: .inMemory).container)
        let clock = clock
        coordinator = PlaybackCoordinator(
            engine: engine, sessions: service, progressStore: progressStore, settings: settings, policy: policy,
            lastPlayedStore: lastPlayed, now: { clock.now })
        let events = EventLog()
        coordinator.addObserver { events.events.append($0) }
        self.events = events
    }

    private func key(_ itemID: String) -> MediaKey {
        MediaKey(serverConnectionID: connectionID, libraryItemId: itemID)
    }

    private func setServerProgress(_ itemID: String, time: Double, updated: Date, finished: Bool = false) {
        service.state.withLock {
            $0.serverTime[itemID] = time
            $0.progress[itemID] = MediaProgress(
                id: "p-\(itemID)", libraryItemId: itemID, duration: 3600, currentTime: time, isFinished: finished,
                lastUpdate: Int(updated.timeIntervalSince1970 * 1000))
        }
    }

    private func setLocalProgress(_ itemID: String, time: Double, updated: Date) async throws {
        try await progressStore.recordEdit(
            ProgressEdit(audio: .init(currentTime: time, duration: 3600, progress: time / 3600)), for: key(itemID),
            now: updated)
    }

    /// Yields until `condition` holds (a suspended task reached a gate).
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }

    // MARK: - Start and resume

    @Test func playStartsSessionAtNewestProgressWithRewindAndSavedRate() async throws {
        settings.playbackRate = 1.5
        setServerProgress("A", time: 300, updated: clock.ago(3600))
        try await setLocalProgress("A", time: 500, updated: clock.ago(120))

        await coordinator.play(itemID: "A")

        // Local is newer; 2 min since then rewinds 10 s.
        #expect(engine.loads.map(\.time) == [490])
        #expect(engine.defaultRate == 1.5)
        #expect(coordinator.rate == 1.5)
        #expect(coordinator.phase == .loaded)
        #expect(coordinator.isPlaying)
        #expect(coordinator.mediaKey == key("A"))
        #expect(coordinator.session?.id == StubSessionService.sessionID(for: "A"))
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
            events.events == [
                .itemChanged(key("A")),
                .sessionStarted(sessionID: StubSessionService.sessionID(for: "A"), key: key("A")),
                .loaded(time: 490), .didSeek(time: 490), .playbackStarted,
            ])
        #expect(lastPlayed.record?.position == 490)
    }

    @Test func newerServerProgressWinsWithLongPauseRewind() async throws {
        setServerProgress("A", time: 800, updated: clock.ago(2 * 3600))
        try await setLocalProgress("A", time: 500, updated: clock.ago(3 * 3600))

        await coordinator.play(itemID: "A")

        #expect(engine.loads.map(\.time) == [770])
    }

    @Test func explicitStartTimeAndDisabledAutoRewindSkipRewind() async throws {
        setServerProgress("A", time: 800, updated: clock.ago(3600))
        await coordinator.play(itemID: "A", startTime: 1234)
        #expect(engine.loads.last?.time == 1234)

        settings.disableAutoRewind = true
        await coordinator.play(itemID: "B")
        setServerProgress("A", time: 800, updated: clock.ago(3600))
        await coordinator.play(itemID: "A")
        #expect(engine.loads.last?.time == 800)
    }

    @Test func finishedItemStartsFromBeginning() async throws {
        setServerProgress("A", time: 3600, updated: clock.ago(60), finished: true)
        await coordinator.play(itemID: "A")
        #expect(engine.loads.map(\.time) == [0])
    }

    @Test func resumeAfterPauseRewindsForPauseLength() async throws {
        await coordinator.play(itemID: "A", startTime: 1000)
        coordinator.pause()
        #expect(!coordinator.isPlaying)
        #expect(events.events.last == .paused(time: 1000))
        clock.advance(by: 6 * 60)

        await coordinator.resume()

        #expect(engine.seeks == [980])
        #expect(coordinator.isPlaying)
        #expect(Array(events.events.suffix(2)) == [.didSeek(time: 980), .playbackStarted])
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
        #expect(Array(events.events.suffix(2)) == [.didSeek(time: 970), .playbackStarted])
    }

    @Test func seekReturnsLandingAndSetRateSaves() async throws {
        await coordinator.play(itemID: "A")
        #expect(await coordinator.seek(to: 5000) == 3600)
        #expect(events.events.last == .didSeek(time: 3600))

        coordinator.setRate(2)
        #expect(settings.playbackRate == 2)
        #expect(engine.defaultRate == 2)
        coordinator.setRate(-1)
        #expect(coordinator.rate == 2)
    }

    // MARK: - Cellular policy

    @Test func deniedStreamingPolicyBlocksWithoutSession() async {
        policy.decision = .denied(.cellular)

        await coordinator.play(itemID: "A")

        #expect(coordinator.error == .streamingNotAllowed(.cellular))
        #expect(service.starts.isEmpty)
        #expect(engine.loads.isEmpty)
        #expect(coordinator.phase == .unloaded)
        #expect(events.events.last == .failed(.streamingNotAllowed(.cellular)))

        await coordinator.play(itemID: "A", allowingMeteredNetwork: true)
        #expect(service.starts.isEmpty)
    }

    @Test func askPolicyNeedsConfirmationThenPlays() async {
        policy.decision = .askUser(.lowDataMode)

        await coordinator.play(itemID: "A")
        #expect(coordinator.error == .streamingNeedsConfirmation(.lowDataMode))
        #expect(service.starts.isEmpty)

        await coordinator.play(itemID: "A", allowingMeteredNetwork: true)
        #expect(coordinator.error == nil)
        #expect(service.starts == ["A"])
        #expect(coordinator.isPlaying)
    }

    // MARK: - Closing

    @Test func switchingItemsClosesPreviousSessionOnce() async {
        await coordinator.play(itemID: "A")
        await coordinator.play(itemID: "B")
        await coordinator.waitForPendingCloses()

        #expect(service.closes == [StubSessionService.sessionID(for: "A")])
        #expect(coordinator.mediaKey == key("B"))
        #expect(coordinator.isPlaying)
        #expect(
            events.events.contains(
                .sessionWillClose(
                    ClosingSession(
                        sessionID: StubSessionService.sessionID(for: "A"), key: key("A"), currentTime: 0,
                        duration: 3600, reason: .itemChanged))))

        coordinator.stop()
        await coordinator.waitForPendingCloses()
        #expect(service.closes == ["A", "B"].map(StubSessionService.sessionID(for:)))
        #expect(coordinator.phase == .idle)
        #expect(lastPlayed.record == nil)
        #expect(events.events.last == .itemChanged(nil))
    }

    @Test func finalCloseReportIsSent() async {
        var closing: [ClosingSession] = []
        coordinator.finalCloseReport = {
            closing.append($0)
            return PlaybackSyncReport(currentTime: $0.currentTime, timeListened: 0, duration: $0.duration)
        }
        await coordinator.play(itemID: "A", startTime: 42)
        coordinator.stop()
        #expect(closing.map(\.currentTime) == [42])
        #expect(closing.map(\.reason) == [.stopped])
    }

    @Test func failedCloseDoesNotBlockNextPlay() async {
        service.state.withLock { $0.closeError = .network(.notConnectedToInternet) }
        await coordinator.play(itemID: "A")
        await coordinator.play(itemID: "B")
        await coordinator.waitForPendingCloses()

        #expect(service.closes == [StubSessionService.sessionID(for: "A")])
        #expect(coordinator.mediaKey == key("B"))
        #expect(coordinator.isPlaying)
        #expect(coordinator.error == nil)
    }

    @Test func lateSessionStartIsClosedAndDiscarded() async {
        let gate = Gate()
        service.state.withLock { $0.startGates["A"] = gate }
        let first = Task { await coordinator.play(itemID: "A") }
        await waitUntil { service.starts == ["A"] }

        await coordinator.play(itemID: "B")
        gate.open()
        await first.value
        await coordinator.waitForPendingCloses()

        #expect(coordinator.mediaKey == key("B"))
        #expect(coordinator.session?.id == StubSessionService.sessionID(for: "B"))
        #expect(coordinator.isPlaying)
        #expect(engine.loads.count == 1)
        #expect(service.closes == [StubSessionService.sessionID(for: "A")])
    }

    @Test func lateEngineLoadIsSupersededAndSessionClosedOnce() async {
        let gate = Gate()
        engine.loadGates = [gate]
        let first = Task { await coordinator.play(itemID: "A") }
        await waitUntil { engine.loads.count == 1 }
        #expect(coordinator.isBuffering)

        await coordinator.play(itemID: "B")
        gate.open()
        await first.value
        await coordinator.waitForPendingCloses()

        #expect(coordinator.mediaKey == key("B"))
        #expect(coordinator.phase == .loaded)
        #expect(coordinator.isPlaying)
        #expect(service.closes == [StubSessionService.sessionID(for: "A")])
    }

    @Test func pauseWhileStartingLoadsPaused() async {
        let gate = Gate()
        engine.loadGates = [gate]
        let first = Task { await coordinator.play(itemID: "A") }
        await waitUntil { engine.loads.count == 1 }
        coordinator.pause()
        gate.open()
        await first.value

        #expect(coordinator.phase == .loaded)
        #expect(!coordinator.isPlaying)
    }

    // MARK: - Errors

    @Test func sessionStartFailureIsSurfaced() async {
        service.state.withLock { $0.startError = .forbidden(message: nil) }
        await coordinator.play(itemID: "A")
        #expect(coordinator.error == .sessionStartFailed(.forbidden(message: nil)))
        #expect(coordinator.phase == .unloaded)
        #expect(coordinator.mediaKey == key("A"))
    }

    @Test func engineLoadFailureClosesSessionAndSurfacesPlaybackFailure() async {
        let failure = PlaybackFailure(
            kind: .http(status: 404), domain: "CoreMediaErrorDomain", code: -12938, description: "404")
        engine.loadError = .itemFailed(trackIndex: 0, failure)

        await coordinator.play(itemID: "A")
        await coordinator.waitForPendingCloses()

        #expect(coordinator.error == .playback(failure))
        #expect(coordinator.phase == .unloaded)
        #expect(service.closes == [StubSessionService.sessionID(for: "A")])
    }

    @Test func engineFailureEventIsSurfaced() async {
        await coordinator.play(itemID: "A")
        let failure = PlaybackFailure(kind: .network, domain: NSURLErrorDomain, code: -1009, description: "offline")
        engine.onEvent?(.failed(.playerFailed(failure)))

        #expect(coordinator.error == .playback(failure))
        #expect(events.events.last == .failed(.playback(failure)))
    }

    // MARK: - Restore

    @Test func restoreIsLazyAndFirstPlayResumesFromRecord() async {
        lastPlayed.record = LastPlayedRecord(
            serverConnectionID: connectionID, libraryItemID: "A", episodeID: nil, position: 600, duration: 3600,
            timestamp: clock.ago(10 * 60))
        setServerProgress("A", time: 100, updated: clock.ago(86_400))

        #expect(coordinator.restoreLastPlayed())

        #expect(coordinator.phase == .unloaded)
        #expect(coordinator.mediaKey == key("A"))
        #expect(coordinator.currentTime == 600)
        #expect(coordinator.duration == 3600)
        #expect(!coordinator.isPlaying)
        #expect(service.starts.isEmpty)
        #expect(engine.loads.isEmpty)
        #expect(events.events == [.itemChanged(key("A"))])

        await coordinator.resume()

        // The record is newest; 10 min since then rewinds 20 s.
        #expect(service.starts == ["A"])
        #expect(engine.loads.map(\.time) == [580])
        #expect(coordinator.isPlaying)
    }

    @Test func seekWhileRestoredSetsExplicitStart() async {
        lastPlayed.record = LastPlayedRecord(
            serverConnectionID: connectionID, libraryItemID: "A", episodeID: nil, position: 600, duration: 3600,
            timestamp: clock.ago(3600))
        coordinator.restoreLastPlayed()

        #expect(await coordinator.seek(to: 1200) == 1200)
        await coordinator.resume()

        #expect(engine.loads.map(\.time) == [1200])
    }

    @Test func restoreIgnoresOtherConnectionsAndLoadedState() async {
        lastPlayed.record = LastPlayedRecord(
            serverConnectionID: UUID(), libraryItemID: "A", episodeID: nil, position: 600, duration: nil,
            timestamp: clock.now)
        #expect(!coordinator.restoreLastPlayed())
        #expect(coordinator.phase == .idle)

        await coordinator.play(itemID: "B")
        lastPlayed.record?.serverConnectionID = connectionID
        #expect(!coordinator.restoreLastPlayed())
        #expect(coordinator.mediaKey == key("B"))
    }

    @Test func lastPlayedIsSavedOnPauseAndThrottledTicks() async {
        await coordinator.play(itemID: "A", episodeID: "E", startTime: 100)
        #expect(lastPlayed.record?.episodeID == "E")
        engine.onEvent?(.tick(105))
        #expect(lastPlayed.record?.position == 100)
        clock.advance(by: 20)
        engine.onEvent?(.tick(120))
        #expect(lastPlayed.record?.timestamp == clock.now)
        coordinator.pause()
        #expect(lastPlayed.record?.timestamp == clock.now)
        #expect(events.events.contains(.tick(time: 105)))
    }
}
