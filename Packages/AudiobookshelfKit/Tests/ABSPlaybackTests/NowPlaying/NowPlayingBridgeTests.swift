import ABSCore
import ABSData
import AppIntents
import Foundation
import NowPlaying
import Observation
import Synchronization
import Testing
import _NowPlaying_AppIntents

@testable import ABSPlayback

/// The user's Now Playing settings, changed by tests at runtime.
@MainActor
@Observable
final class ObservableNowPlayingSettings {
    var value: NowPlayingSettings

    init(_ value: NowPlayingSettings) {
        self.value = value
    }
}

final class CoverCalls: Sendable {
    private let covers = Mutex<[NowPlayingCover]>([])

    var all: [NowPlayingCover] { covers.withLock { $0 } }
    func record(_ cover: NowPlayingCover) { covers.withLock { $0.append(cover) } }
}

/// A coordinator with fakes, bridged to a controller that publishes to fake sessions.
@MainActor
struct BridgeHarness {
    nonisolated static let coverData = Data("cover".utf8)

    let h: CoordinatorHarness
    let settings: ObservableNowPlayingSettings
    let sessions = NowPlayingHarness.SessionLog()
    let covers = CoverCalls()
    let bridge: NowPlayingBridge

    var coordinator: PlaybackCoordinator { h.coordinator }
    var controller: NowPlayingController { bridge.controller }
    var session: FakeNowPlayingSession {
        get throws { try #require(sessions.made.last) }
    }

    /// - Parameter artwork: Holds each cover load until the test resolves its path.
    init(
        _ h: CoordinatorHarness? = nil,
        settings: NowPlayingSettings = NowPlayingSettings(
            jumpForwardTime: 30, jumpBackwardsTime: 15, chapterTrack: false),
        artwork: ArtworkGate? = nil
    ) throws {
        let h = try h ?? CoordinatorHarness()
        self.h = h
        self.settings = ObservableNowPlayingSettings(settings)
        bridge = Self.makeBridge(h, settings: self.settings, sessions: sessions, covers: covers, artwork: artwork)
    }

    static func makeBridge(
        _ h: CoordinatorHarness, settings: ObservableNowPlayingSettings, sessions: NowPlayingHarness.SessionLog,
        covers: CoverCalls, artwork: ArtworkGate? = nil
    ) -> NowPlayingBridge {
        let clock = h.clock
        return NowPlayingBridge(
            coordinator: h.coordinator, settings: { settings.value },
            coverProvider: { cover in
                covers.record(cover)
                if let artwork { return await artwork.load(cover.coverPath) }
                return coverData
            },
            entityIdentifiers: { [EntityIdentifier(for: TestBookEntity.self, identifier: $0.libraryItemId)] },
            now: { clock.now },
            makeSession: {
                let session = FakeNowPlayingSession()
                sessions.made.append(session)
                return session
            })
    }

    /// Starts playing `itemID` with its session start held, returning once the coordinator waits on it.
    func playHeld(_ itemID: String) async -> (task: Task<Void, Never>, gate: Gate) {
        let gate = Gate()
        h.service.state.withLock { $0.startGates[itemID] = gate }
        let coordinator = coordinator
        let task = Task { await coordinator.play(itemID: itemID) }
        await yieldUntil { h.service.starts.last == itemID && coordinator.phase == .starting }
        return (task, gate)
    }

    func snapshot(_ state: MediaPlaybackSnapshot.PlaybackState, at elapsed: Double) -> MediaPlaybackSnapshot {
        MediaPlaybackSnapshot(state: state, elapsedTime: elapsed, timestamp: h.clock.now)
    }

    /// Whether `session` published playing or buffering at 0 or 30 s (the clock not having moved).
    func wasShownPlaying(_ session: FakeNowPlayingSession) -> Bool {
        let shownPlaying = [0.0, 30].flatMap { [snapshot(.playing(rate: 1), at: $0), snapshot(.buffering, at: $0)] }
        return session.snapshots.contains { $0.map(shownPlaying.contains) ?? false }
    }
}

@MainActor
@Suite struct NowPlayingBridgeTests {
    // MARK: State

    @Test func restoredThenPlayedItemIsPublished() async throws {
        let b = try BridgeHarness()
        b.h.lastPlayed.record = LastPlayedRecord(
            serverConnectionID: b.h.connectionID, libraryItemID: "a", episodeID: nil, position: 120, duration: 3600,
            timestamp: b.h.clock.ago(5), title: "Saved a", author: "Saved author", coverPath: "/covers/a.jpg")
        #expect(b.sessions.made.isEmpty)

        b.coordinator.restoreLastPlayed()
        let session = try b.session
        var book = try #require(session.book)
        #expect(book.id == b.h.key("a").rawValue)
        #expect(book.title == "Saved a")
        #expect(book.authorName == "Saved author")
        #expect(book.duration?.finiteValue == 3600)
        #expect(book.chapter == nil)
        #expect(book.appEntityIdentifiers == [EntityIdentifier(for: TestBookEntity.self, identifier: "a")])
        #expect(session.snapshot == b.snapshot(.paused, at: 120))
        #expect(session.applicationPrimaryRequests == 0)

        await b.controller.artworkTask?.value
        #expect(session.book?.artwork != nil)
        #expect(b.covers.all == [NowPlayingCover(key: b.h.key("a"), coverPath: "/covers/a.jpg")])

        await b.coordinator.play(itemID: "a")
        book = try #require(session.book)
        #expect(book.title == "Title a")
        #expect(book.authorName == "Author")
        #expect(book.chapter?.current == 1)
        #expect(book.chapter?.total == 2)
        #expect(book.artwork != nil)
        #expect(session.snapshot == b.snapshot(.playing(rate: 1), at: 120))
        // Same item and cover: the artwork isn't loaded again.
        #expect(b.covers.all.count == 1)
        #expect(b.sessions.made.count == 1)
        await b.controller.activationTask?.value
        #expect(session.applicationPrimaryRequests == 1)
    }

    @Test func directUnloadedPositionChangesPublishAfterObservationRegisters() async throws {
        let b = try BridgeHarness()
        b.h.lastPlayed.record = b.h.record("a", position: 120, age: 5)
        b.coordinator.restoreLastPlayed()
        let session = try b.session
        // This is applied by the observation callback, after it re-registers for the restored phase.
        b.settings.value.jumpForwardTime = 45
        await yieldUntil { b.controller.publishedCommands?.skipForwardInterval == 45 }
        await b.controller.artworkTask?.value
        let events = b.h.events.events

        await b.coordinator.jump(by: 30)
        await yieldUntil { session.snapshot == b.snapshot(.paused, at: 150) }
        await b.coordinator.seek(to: 600)
        await yieldUntil { session.snapshot == b.snapshot(.paused, at: 600) }
        await b.coordinator.jump(by: -15)
        await yieldUntil { session.snapshot == b.snapshot(.paused, at: 585) }

        #expect(b.controller.state?.elapsed == 585, "Published elapsed: \(b.controller.state?.elapsed ?? -1)")
        #expect(b.h.events.events == events)
        #expect(b.h.service.starts.isEmpty)
        #expect(b.h.engine.loads.isEmpty)
        #expect(session.applicationPrimaryRequests == 0)
    }

    @Test func loadedTicksMatchingExtrapolationDoNotRepublishSnapshots() async throws {
        let b = try BridgeHarness()
        await b.coordinator.play(itemID: "a", startTime: 120)
        let session = try b.session
        b.settings.value.jumpForwardTime = 45
        await yieldUntil { b.controller.publishedCommands?.skipForwardInterval == 45 }
        await b.controller.artworkTask?.value
        await b.controller.activationTask?.value
        let snapshots = session.snapshots.count

        for time in 121...140 {
            b.h.clock.advance(by: 1)
            b.h.engine.currentTime = Double(time)
            b.h.engine.onEvent?(.tick(Double(time)))
            await Task.yield()
        }
        #expect(b.controller.state?.elapsed == 140)
        #expect(session.snapshots.count == snapshots)
        #expect(session.applicationPrimaryRequests == 1)
    }

    @Test func pendingAbsoluteSeekAndJumpPublishBeforeEngineLoadCompletes() async throws {
        let b = try BridgeHarness()
        let gate = Gate()
        b.h.engine.loadGates = [gate]
        let coordinator = b.coordinator
        let play = Task { await coordinator.play(itemID: "a") }
        await yieldUntil { b.h.engine.loads.count == 1 }
        let session = try b.session
        b.settings.value.jumpForwardTime = 45
        await yieldUntil { b.controller.publishedCommands?.skipForwardInterval == 45 }

        await coordinator.seek(to: 1000)
        await yieldUntil { session.snapshot == b.snapshot(.paused, at: 1000) }
        await coordinator.jump(by: -15)
        await yieldUntil { session.snapshot == b.snapshot(.paused, at: 985) }
        #expect(coordinator.currentTime == 985)
        #expect(session.applicationPrimaryRequests == 0)
        gate.open()
        await play.value
        #expect(session.snapshot == b.snapshot(.playing(rate: 1), at: 985))
    }

    @Test func itemAndChapterChangesRepublishTheContent() async throws {
        let b = try BridgeHarness()
        await b.coordinator.play(itemID: "a")
        let session = try b.session
        #expect(session.book?.chapter?.current == 1)
        await b.controller.artworkTask?.value
        #expect(b.covers.all == [NowPlayingCover(key: b.h.key("a"), coverPath: "/covers/a.jpg")])

        b.h.engine.currentTime = 1500
        b.h.engine.onEvent?(.tick(1500))
        #expect(session.book?.chapter?.current == 2)
        #expect(session.snapshot == b.snapshot(.playing(rate: 1), at: 1500))

        await b.coordinator.play(itemID: "b")
        #expect(session.book?.id == b.h.key("b").rawValue)
        #expect(session.book?.title == "Title b")
        #expect(session.book?.chapter?.current == 1)
        await b.controller.artworkTask?.value
        #expect(b.covers.all.count == 2)
        #expect(b.covers.all.last == NowPlayingCover(key: b.h.key("b"), coverPath: "/covers/b.jpg"))
    }

    @Test func playPauseRateAndSeekUpdateTheSnapshot() async throws {
        let b = try BridgeHarness()
        await b.coordinator.play(itemID: "a")
        let session = try b.session
        #expect(session.snapshot == b.snapshot(.playing(rate: 1), at: 0))

        // A rate change from the app emits no event; the bridge observes it.
        b.coordinator.setRate(2)
        await yieldUntil { session.snapshot == b.snapshot(.playing(rate: 2), at: 0) }

        await b.coordinator.seek(to: 500)
        #expect(session.snapshot == b.snapshot(.playing(rate: 2), at: 500))

        b.coordinator.pause()
        #expect(session.snapshot == b.snapshot(.paused, at: 500))

        await b.coordinator.resume()
        #expect(session.snapshot == b.snapshot(.playing(rate: 2), at: 500))
    }

    @Test func stopClearsTheSession() async throws {
        let b = try BridgeHarness()
        await b.coordinator.play(itemID: "a")
        let session = try b.session

        b.coordinator.stop()
        #expect(session.content == nil)
        #expect(session.snapshot == nil)
        #expect(session.commandUpdates.last?.isEmpty == true)
        #expect(!b.controller.isActive)
        await #expect(throws: NowPlayingCommandError.noPlayer) { try await b.controller.perform(.togglePlayPause) }
    }

    // MARK: Commands

    @Test func transportCommandsReachTheCoordinator() async throws {
        let b = try BridgeHarness()
        await b.coordinator.play(itemID: "a")

        try await b.controller.perform(.pause)
        #expect(!b.coordinator.isPlaying)
        try await b.controller.perform(.play)
        #expect(b.coordinator.isPlaying)
        try await b.controller.perform(.togglePlayPause)
        #expect(!b.coordinator.isPlaying)
        try await b.controller.perform(.togglePlayPause)
        #expect(b.coordinator.isPlaying)
        #expect(try b.session.snapshot == b.snapshot(.playing(rate: 1), at: 0))
    }

    @Test func skipsAndTrackCommandsJumpByTheUsersIntervals() async throws {
        let b = try BridgeHarness()
        await b.coordinator.play(itemID: "a")
        b.h.engine.currentTime = 100
        let seeksBefore = b.h.engine.seeks.count

        // The system passes the interval it showed for skips.
        try await b.controller.perform(.skipForward(30))
        try await b.controller.perform(.skipBackward(15))
        // Next and previous track use the settings (AirPods double and triple press).
        try await b.controller.perform(.nextTrack)
        try await b.controller.perform(.previousTrack)
        #expect(Array(b.h.engine.seeks.dropFirst(seeksBefore)) == [130, 115, 145, 130])
        #expect(try b.session.snapshot == b.snapshot(.playing(rate: 1), at: 130))

        b.settings.value.jumpForwardTime = 60
        b.settings.value.jumpBackwardsTime = 5
        await yieldUntil { b.controller.publishedCommands?.skipForwardInterval == 60 }
        #expect(b.controller.publishedCommands?.skipBackwardInterval == 5)
        try await b.controller.perform(.nextTrack)
        try await b.controller.perform(.previousTrack)
        #expect(Array(b.h.engine.seeks.suffix(2)) == [190, 185])

        // Jumps are clamped to the item.
        try await b.controller.perform(.skipForward(9999))
        #expect(b.h.engine.seeks.last == 3600)
        b.h.engine.currentTime = 3
        try await b.controller.perform(.skipBackward(15))
        #expect(b.h.engine.seeks.last == 0)
    }

    @Test func rateCommandSavesAndPublishesTheRate() async throws {
        let b = try BridgeHarness()
        await b.coordinator.play(itemID: "a")

        try await b.controller.perform(.changeRate(1.5))
        #expect(b.h.settings.playbackRate == 1.5)
        #expect(b.h.engine.defaultRate == 1.5)
        #expect(try b.session.snapshot == b.snapshot(.playing(rate: 1.5), at: 0))
    }

    @Test func seekingFollowsTheSettingAtRuntime() async throws {
        let b = try BridgeHarness()
        await b.coordinator.play(itemID: "a")
        let session = try b.session
        #expect(b.controller.publishedCommands?.canSeek == false)
        #expect(session.commandUpdates.last?.count == 8)
        let seeksBefore = b.h.engine.seeks
        await #expect(throws: NowPlayingCommandError.seekingDisabled) { try await b.controller.perform(.seek(100)) }
        #expect(b.h.engine.seeks == seeksBefore)

        b.settings.value.allowSeekingOnMediaControls = true
        await yieldUntil { b.controller.publishedCommands?.canSeek == true }
        #expect(session.commandUpdates.last?.count == 9)
        try await b.controller.perform(.seek(100))
        #expect(b.h.engine.seeks.last == 100)
        #expect(session.snapshot == b.snapshot(.playing(rate: 1), at: 100))

        b.settings.value.allowSeekingOnMediaControls = false
        await yieldUntil { b.controller.publishedCommands?.canSeek == false }
        #expect(session.commandUpdates.last?.count == 8)
        await #expect(throws: NowPlayingCommandError.seekingDisabled) { try await b.controller.perform(.seek(200)) }
        #expect(b.h.engine.seeks.last == 100)
    }

    @Test func commandsWithNothingLoadedFailWithoutTouchingTheCoordinator() async throws {
        let b = try BridgeHarness()
        #expect(!b.controller.isActive)
        #expect(b.sessions.made.isEmpty)

        let commands: [NowPlayingCommand] = [
            .play, .pause, .togglePlayPause, .skipForward(30), .skipBackward(15), .nextTrack, .previousTrack,
            .seek(10), .changeRate(2),
        ]
        for command in commands {
            await #expect(throws: NowPlayingCommandError.noPlayer) { try await b.controller.perform(command) }
        }
        #expect(b.coordinator.phase == .idle)
        #expect(b.h.policy.checks == 0)
        #expect(b.h.service.starts.isEmpty)
        #expect(b.h.engine.seeks.isEmpty)
        #expect(b.h.settings.playbackRate == 1)
        #expect(b.sessions.made.isEmpty)
    }

    @Test func skipsWhileStartingApplyAfterTheResumePosition() async throws {
        let b = try BridgeHarness()
        b.h.settings.disableAutoRewind = true
        b.h.setServerProgress("a", time: 500, updated: b.h.clock.ago(10))
        let (play, gate) = await b.playHeld("a")

        // The coordinator has no position yet; jumps wait for the resume position.
        try await b.controller.perform(.skipForward(30))
        try await b.controller.perform(.nextTrack)
        try await b.controller.perform(.previousTrack)
        gate.open()
        await play.value

        #expect(b.h.engine.loads.last?.time == 500)
        #expect(b.h.engine.seeks == [545])
        #expect(b.coordinator.currentTime == 545)
        #expect(b.coordinator.isPlaying)
        #expect(try b.session.snapshot == b.snapshot(.playing(rate: 1), at: 545))
    }

    @Test(arguments: [false, true])
    func skipsOnARestoredItemKeepProgressFromElsewhere(elsewhere: Bool) async throws {
        let b = try BridgeHarness()
        b.h.settings.disableAutoRewind = true
        b.h.lastPlayed.record = b.h.record("a", position: 120, age: 3600)
        if elsewhere { b.h.setServerProgress("a", time: 500, updated: b.h.clock.now) }
        b.coordinator.restoreLastPlayed()

        try await b.controller.perform(.skipForward(30))
        #expect(b.coordinator.currentTime == 150)
        #expect(try b.session.snapshot == b.snapshot(.paused, at: 150))

        // Played: the skip applies to the resolved position, which newer progress from elsewhere wins.
        await b.coordinator.resume()
        let resume: Double = elsewhere ? 500 : 120
        #expect(b.h.engine.loads.last?.time == resume)
        #expect(b.h.engine.seeks == [resume + 30])
    }

    @Test func skipsWhileStartingAreDroppedWithTheStart() async throws {
        let b = try BridgeHarness()
        b.h.settings.disableAutoRewind = true
        b.h.setServerProgress("a", time: 500, updated: b.h.clock.ago(10))
        b.h.service.state.withLock { $0.startError = .forbidden(message: nil) }
        let (play, gate) = await b.playHeld("a")
        try await b.controller.perform(.skipForward(30))
        gate.open()
        await play.value
        #expect(b.coordinator.error != nil)

        // A retry starts at the resume position, without the failed start's skip.
        b.h.service.state.withLock { $0.startError = nil }
        await b.coordinator.resume()
        #expect(b.h.engine.loads.last?.time == 500)
        #expect(b.h.engine.seeks.isEmpty)
    }

    @Test func rapidSkipsAddUp() async throws {
        let b = try BridgeHarness()
        await b.coordinator.play(itemID: "a")
        b.h.engine.currentTime = 100
        let gate = Gate()
        b.h.engine.seekGates = [gate]

        let first = Task { try await b.controller.perform(.skipForward(30)) }
        await yieldUntil { b.h.engine.seeks == [130] }
        // The first seek is still in flight: the second jumps from its target.
        try await b.controller.perform(.skipForward(30))
        gate.open()
        try await first.value
        #expect(b.h.engine.seeks == [130, 160])
        #expect(b.coordinator.currentTime == 160)
        #expect(try b.session.snapshot == b.snapshot(.playing(rate: 1), at: 160))
    }

    @Test func toggleWhileStartingLoadsPaused() async throws {
        let b = try BridgeHarness()
        let (play, gate) = await b.playHeld("a")

        try await b.controller.perform(.togglePlayPause)
        #expect(!b.coordinator.isPlaybackRequested)
        gate.open()
        await play.value

        #expect(b.coordinator.phase == .loaded)
        #expect(!b.coordinator.isPlaying)
        #expect(!b.h.engine.isPlaybackRequested)
        #expect(try b.session.snapshot == b.snapshot(.paused, at: 0))
        // Toggling again plays.
        try await b.controller.perform(.togglePlayPause)
        #expect(b.coordinator.isPlaying)
    }

    @Test func aStallShowsPauseAndToggleStopsIt() async throws {
        let b = try BridgeHarness()
        await b.coordinator.play(itemID: "a")
        let session = try b.session
        b.h.engine.currentTime = 200

        // Stalled with play requested: shown as buffering (elapsed held), so the system offers pause.
        b.h.engine.state = .buffering
        #expect(!b.coordinator.isPlaying)
        #expect(b.coordinator.isPlaybackRequested)
        await yieldUntil { session.snapshot == b.snapshot(.buffering, at: 200) }

        try await b.controller.perform(.togglePlayPause)
        #expect(!b.h.engine.isPlaybackRequested)
        #expect(!b.coordinator.isPlaybackRequested)
        #expect(session.snapshot == b.snapshot(.paused, at: 200))
    }

    @Test func toggleBeforeTheEngineStartsKeepsItPausedAndInactive() async throws {
        let b = try BridgeHarness()
        let (play, gate) = await b.playHeld("a")
        try await b.controller.perform(.skipForward(30))
        let seekGate = Gate()
        b.h.engine.seekGates = [seekGate]
        gate.open()
        await yieldUntil { b.h.engine.seeks == [30] }
        let session = try b.session

        // Loaded with the catch-up seek in flight, the engine still loading: not shown as playing.
        b.h.engine.state = .loading
        #expect(b.coordinator.isPlaybackRequested)
        try await b.controller.perform(.togglePlayPause)
        #expect(!b.coordinator.isPlaybackRequested)
        seekGate.open()
        await play.value

        #expect(!b.coordinator.isPlaying)
        #expect(!b.h.engine.isPlaybackRequested)
        #expect(session.snapshot == b.snapshot(.paused, at: 30))
        let shownPlaying = [0.0, 30].flatMap {
            [b.snapshot(.playing(rate: 1), at: $0), b.snapshot(.buffering, at: $0)]
        }
        #expect(!session.snapshots.contains { $0.map(shownPlaying.contains) ?? false })
        #expect(session.applicationPrimaryRequests == 0)

        // A real play activates.
        try await b.controller.perform(.play)
        #expect(b.coordinator.isPlaying)
        await b.controller.activationTask?.value
        #expect(session.applicationPrimaryRequests == 1)
    }

    @Test func playingAgainDuringTheCatchUpSeekActivatesOnlyOnceItPlays() async throws {
        let b = try BridgeHarness()
        let (play, gate) = await b.playHeld("a")
        try await b.controller.perform(.skipForward(30))
        let seekGate = Gate()
        b.h.engine.seekGates = [seekGate]
        gate.open()
        await yieldUntil { b.h.engine.seeks == [30] }
        let session = try b.session

        await b.coordinator.play(itemID: "a")
        #expect(!b.h.engine.isPlaybackRequested)
        #expect(!b.wasShownPlaying(session))
        #expect(session.applicationPrimaryRequests == 0)

        seekGate.open()
        await play.value
        #expect(b.coordinator.isPlaying)
        #expect(session.snapshot == b.snapshot(.playing(rate: 1), at: 30))
        await b.controller.activationTask?.value
        #expect(session.applicationPrimaryRequests == 1)
    }

    /// The engine defers playing (and activating its audio session) while a seek is in flight.
    @Test func playDuringASeekIsShownOnlyOnceTheEnginePlays() async throws {
        let b = try BridgeHarness()
        let (play, gate) = await b.playHeld("a")
        try await b.controller.perform(.togglePlayPause)
        gate.open()
        await play.value
        let session = try b.session
        #expect(session.snapshot == b.snapshot(.paused, at: 0))

        let seekGate = Gate()
        let resumeGate = Gate()
        b.h.engine.seekGates = [seekGate, resumeGate]
        let controller = b.controller
        let skip = Task { try await controller.perform(.skipForward(30)) }
        await yieldUntil { b.h.engine.seeks == [30] }
        // Main retries the pending target before playing. Hold that replacement seek too.
        let resume = Task { try await controller.perform(.play) }
        await yieldUntil { b.h.engine.seeks == [30, 30] }
        #expect(b.coordinator.isPlaybackRequested)
        #expect(!b.h.engine.isPlaybackRequested)
        #expect(!b.wasShownPlaying(session))
        #expect(session.applicationPrimaryRequests == 0)

        resumeGate.open()
        try await resume.value
        seekGate.open()
        try await skip.value
        await yieldUntil { session.snapshot == b.snapshot(.playing(rate: 1), at: 30) }
        await b.controller.activationTask?.value
        #expect(session.applicationPrimaryRequests == 1)
    }

    @Test func interruptedLoadAndRemoteJumpPublishThePendingTargetUntilLanding() async throws {
        let b = try BridgeHarness()
        b.h.engine.interruptedLoads = 1
        await b.coordinator.play(itemID: "a", startTime: 1500)
        let session = try b.session
        #expect(session.book?.chapter?.current == 2)
        #expect(session.snapshot == b.snapshot(.paused, at: 1500))
        #expect(session.applicationPrimaryRequests == 0)

        b.h.engine.seekResults = [.interrupted]
        try await b.controller.perform(.nextTrack)
        #expect(b.coordinator.currentTime == 1530)
        #expect(session.snapshot == b.snapshot(.paused, at: 1530))
        #expect(session.applicationPrimaryRequests == 0)
        b.h.engine.landPendingSeek()
        #expect(session.snapshot == b.snapshot(.playing(rate: 1), at: 1530))
        await b.controller.activationTask?.value
        #expect(session.applicationPrimaryRequests == 1)
        #expect(
            b.h.events.events.filter { if case .didSeek = $0 { true } else { false } } == [.didSeek(time: 1530)])
    }

    @Test func refusedEarlyPlayAndSilentRetryStayPausedAndPreserveTheError() async throws {
        let b = try BridgeHarness()
        let (play, gate) = await b.playHeld("a")
        try await b.controller.perform(.nextTrack)
        b.h.engine.failingPlays = 1
        gate.open()
        await play.value
        let failure = try #require(b.coordinator.error)
        let session = try b.session
        #expect(!b.coordinator.isPlaybackRequested)
        #expect(session.snapshot == b.snapshot(.paused, at: 30))
        #expect(session.applicationPrimaryRequests == 0)

        b.h.engine.silentlyRefusingPlays = 1
        try await b.controller.perform(.play)
        #expect(b.coordinator.error == failure)
        #expect(!b.coordinator.isPlaybackRequested)
        #expect(session.snapshot == b.snapshot(.paused, at: 30))
        #expect(session.applicationPrimaryRequests == 0)
        #expect(!b.h.events.events.contains(.playbackStarted))

        try await b.controller.perform(.togglePlayPause)
        #expect(b.coordinator.error == nil)
        #expect(session.snapshot == b.snapshot(.playing(rate: 1), at: 30))
        await b.controller.activationTask?.value
        #expect(session.applicationPrimaryRequests == 1)
    }

    @Test func anInterruptionPauseIsPublished() async throws {
        let b = try BridgeHarness()
        await b.coordinator.play(itemID: "a")
        let session = try b.session
        b.h.engine.currentTime = 200

        // The engine pauses on an audio session interruption without a coordinator event.
        b.h.engine.isPlaybackRequested = false
        b.h.engine.state = .paused
        await yieldUntil { session.snapshot == b.snapshot(.paused, at: 200) }
        #expect(!b.coordinator.isPlaybackRequested)
    }

    @Test func stallsAlternateWithPlayingAndHoldTheElapsedTime() async throws {
        let b = try BridgeHarness()
        await b.coordinator.play(itemID: "a")
        let session = try b.session
        b.h.engine.currentTime = 200

        b.h.engine.state = .buffering
        let firstStall = b.snapshot(.buffering, at: 200)
        await yieldUntil { session.snapshot == firstStall }
        // Ticks while stalled at the same position publish nothing: the elapsed time is held.
        let published = session.snapshots.count
        b.h.clock.advance(by: 5)
        b.h.engine.onEvent?(.tick(200))
        #expect(session.snapshots.count == published)

        b.h.engine.state = .playing
        let resumed = b.snapshot(.playing(rate: 1), at: 200)
        await yieldUntil { session.snapshot == resumed }

        b.h.clock.advance(by: 10)
        b.h.engine.currentTime = 210
        b.h.engine.state = .buffering
        let secondStall = b.snapshot(.buffering, at: 210)
        await yieldUntil { session.snapshot == secondStall }
        #expect(Array(session.snapshots.suffix(3)) == [firstStall, resumed, secondStall])
    }

    @Test func aFailedLoadAndARestartKeepTheMetadata() async throws {
        let b = try BridgeHarness()
        b.h.engine.loadError = .emptyTimeline
        await b.coordinator.play(itemID: "a")
        let session = try b.session
        let failedAt = session.contents.count
        #expect(b.coordinator.error != nil)
        #expect(b.coordinator.session == nil)
        await b.controller.artworkTask?.value
        #expect(session.book?.title == "Title a")
        #expect(session.book?.authorName == "Author")
        let artwork = try #require(session.book?.artwork?.id)

        // Retrying restarts the same item: no blank content, and the artwork isn't reloaded.
        b.h.engine.loadError = nil
        await b.coordinator.resume()
        #expect(b.coordinator.isPlaying)
        #expect(session.book?.artwork?.id == artwork)
        let books = session.contents.dropFirst(failedAt - 1).compactMap { $0 as? BookContent }
        #expect(books.count == session.contents.count - failedAt + 1)
        #expect(books.allSatisfy { $0.title == "Title a" })
        #expect(b.covers.all.count == 1)
    }

    @Test(arguments: [false, true])
    func restoredMetadataDoesNotReplaceLiveMetadataAfterLoadFailure(podcast: Bool) async throws {
        let b = try BridgeHarness()
        var record = b.h.record("a", position: 120, age: 5)
        record.episodeID = podcast ? "e1" : nil
        record.author = "Saved author"
        record.coverPath = "/covers/saved.jpg"
        b.h.lastPlayed.record = record
        let show = PodcastMetadata(title: "Live show")
        let item = LibraryItem(
            id: "a", libraryId: "lib", mediaType: .podcast,
            media: .podcast(
                Podcast(
                    id: "pod", metadata: show,
                    episodes: [PodcastEpisode(id: "e1", publishedAt: 1_700_000_000_000)])))
        b.h.service.state.withLock {
            $0.metadata["a"] = (
                podcast ? .podcast(show) : .book(BookMetadata(title: "Live book", narratorName: "Narrator")),
                podcast ? item : nil
            )
        }
        b.coordinator.restoreLastPlayed()
        #expect(b.controller.state?.title == "Saved a")
        await b.controller.artworkTask?.value
        let gate = Gate()
        b.h.engine.loadGates = [gate]
        b.h.engine.loadError = .emptyTimeline
        let coordinator = b.coordinator
        let play = Task { await coordinator.resume() }
        await yieldUntil { b.h.engine.loads.count == 1 }
        await b.controller.artworkTask?.value
        var live = try #require(b.controller.publishedContent)
        #expect(live.title == "Title a")
        #expect(live.author == (podcast ? "Live show" : "Author"))
        #expect(live.narrator == (podcast ? nil : "Narrator"))
        #expect(live.releaseDate == (podcast ? Date(timeIntervalSince1970: 1_700_000_000) : nil))
        #expect(live.artwork?.key == "\(record.key.rawValue)|/covers/a.jpg")

        gate.open()
        await play.value
        await b.controller.artworkTask?.value
        #expect(coordinator.session == nil)
        #expect(coordinator.restoredRecord == record)
        #expect(b.controller.publishedContent == live)
        #expect(b.controller.state?.title == "Title a", "After failure: \(b.controller.state?.title ?? "")")

        b.h.engine.loadError = nil
        let retryGate = Gate()
        b.h.service.state.withLock { $0.startGates["a"] = retryGate }
        let retry = Task { await coordinator.resume() }
        await yieldUntil { b.h.service.starts.count == 2 }
        #expect(b.controller.publishedContent == live)
        retryGate.open()
        await retry.value
        await b.controller.artworkTask?.value
        live.chapter = .init(current: 1, total: 2)
        #expect(b.controller.publishedContent == live)
        #expect(b.covers.all.count == 2)  // Saved cover, then live cover; no rollback or retry reload.

        coordinator.stop()
        record.title = "Restored again"
        b.h.lastPlayed.record = record
        coordinator.restoreLastPlayed()
        #expect(b.controller.state?.title == "Restored again")
        #expect(b.controller.state?.narrator == nil)
        #expect(b.controller.state?.releaseDate == nil)
    }

    @Test func anItemSwitchNeverBlanksTheOldItem() async throws {
        let b = try BridgeHarness()
        await b.coordinator.play(itemID: "a")
        let session = try b.session
        await b.controller.artworkTask?.value
        let before = session.contents.count

        await b.coordinator.play(itemID: "b")
        let books = session.contents.dropFirst(before).compactMap { $0 as? BookContent }
        let oldItem = books.filter { $0.id == b.h.key("a").rawValue }
        #expect(oldItem.allSatisfy { $0.title == "Title a" && $0.artwork != nil })
        #expect(session.book?.title == "Title b")
    }

    @Test func aStaleCoverLoadDoesNotReplaceTheNewItemsCover() async throws {
        let artwork = ArtworkGate()
        let b = try BridgeHarness(artwork: artwork)
        await b.coordinator.play(itemID: "a")
        let session = try b.session
        await yieldUntil { b.covers.all.count == 1 }

        await b.coordinator.play(itemID: "b")
        await yieldUntil { b.covers.all.count == 2 }
        // A's load finishes after the switch, then B's.
        await artwork.resolve("/covers/a.jpg", with: Data("a".utf8))
        await artwork.resolve("/covers/b.jpg", with: Data("b".utf8))
        await b.controller.artworkTask?.value

        #expect(session.book?.id == b.h.key("b").rawValue)
        #expect(session.book?.artwork?.id == "\(b.h.key("b").rawValue)|/covers/b.jpg")
    }

    @Test func chapterTrackModeShowsTheChapterAndSeeksWithinIt() async throws {
        let b = try BridgeHarness(
            settings: NowPlayingSettings(
                jumpForwardTime: 30, jumpBackwardsTime: 15, allowSeekingOnMediaControls: true, chapterTrack: true))
        await b.coordinator.play(itemID: "a")
        let session = try b.session
        #expect(session.book?.title == "One")
        #expect(session.book?.duration?.finiteValue == 1000)

        b.h.engine.currentTime = 1500
        b.h.engine.onEvent?(.tick(1500))
        #expect(session.book?.chapter?.current == 2)
        #expect(session.snapshot == b.snapshot(.playing(rate: 1), at: 500))

        // The scrubber is chapter-relative: 100 into chapter two is 1100 globally.
        try await b.controller.perform(.seek(100))
        #expect(b.h.engine.seeks.last == 1100)
        #expect(session.snapshot == b.snapshot(.playing(rate: 1), at: 100))
    }

    @Test func podcastEpisodesShowTheShowAndReleaseDate() async throws {
        let b = try BridgeHarness()
        let show = PodcastMetadata(title: "The Show", author: "Host")
        let published = 1_700_000_000_000
        let item = LibraryItem(
            id: "p", libraryId: "lib", mediaType: .podcast,
            media: .podcast(
                Podcast(
                    id: "pod", metadata: show,
                    episodes: [PodcastEpisode(id: "e0"), PodcastEpisode(id: "e1", publishedAt: published)])))
        b.h.service.state.withLock { $0.metadata["p"] = (.podcast(show), item) }

        await b.coordinator.play(itemID: "p", episodeID: "e1")
        let podcast = try #require(try b.session.podcast)
        #expect(podcast.episodeTitle == "Title p")
        #expect(podcast.showName == "The Show")
        #expect(podcast.releaseDate == Date(timeIntervalSince1970: 1_700_000_000))
        let state = try #require(b.controller.state)
        #expect(state.narrator == nil)
    }

    // MARK: Lifetime

    @Test func invalidateEndsTheSessionAndStopsFollowing() async throws {
        let b = try BridgeHarness()
        await b.coordinator.play(itemID: "a")
        let session = try b.session

        b.bridge.invalidate()
        #expect(!b.controller.isActive)
        #expect(session.content == nil)
        #expect(session.snapshot == nil)
        #expect(b.controller.commandHandler == nil)

        let updates = (session.contents.count, session.snapshots.count)
        b.coordinator.pause()
        await b.coordinator.play(itemID: "b")
        #expect(b.sessions.made.count == 1)
        #expect(session.contents.count == updates.0)
        #expect(session.snapshots.count == updates.1)
        b.bridge.invalidate()
    }

    @Test func releasingTheBridgeEndsTheSessionAndKeepsTheCoordinator() async throws {
        let h = try CoordinatorHarness()
        let sessions = NowPlayingHarness.SessionLog()
        weak var weakBridge: NowPlayingBridge?
        do {
            let bridge = BridgeHarness.makeBridge(
                h, settings: ObservableNowPlayingSettings(NowPlayingSettings()), sessions: sessions,
                covers: CoverCalls())
            weakBridge = bridge
            await h.coordinator.play(itemID: "a")
        }
        #expect(weakBridge == nil)
        let session = try #require(sessions.made.last)
        #expect(session.content == nil)

        // The coordinator carries on without it.
        h.coordinator.pause()
        await h.coordinator.resume()
        #expect(h.coordinator.isPlaying)
        #expect(sessions.made.count == 1)
    }

    @Test func theBridgeDoesNotKeepTheCoordinatorAlive() async throws {
        weak var weakCoordinator: PlaybackCoordinator?
        let sessions = NowPlayingHarness.SessionLog()
        let bridge: NowPlayingBridge
        do {
            let h = try CoordinatorHarness()
            h.lastPlayed.record = h.record("a", position: 10, age: 5)
            bridge = BridgeHarness.makeBridge(
                h, settings: ObservableNowPlayingSettings(NowPlayingSettings()), sessions: sessions,
                covers: CoverCalls())
            h.coordinator.restoreLastPlayed()
            weakCoordinator = h.coordinator
        }
        #expect(weakCoordinator == nil)
        #expect(bridge.controller.isActive)

        // A command (or the next refresh) notices, ends the session and fails.
        await #expect(throws: NowPlayingCommandError.noPlayer) { try await bridge.controller.perform(.skipForward(30)) }
        #expect(bridge.isInvalidated)
        #expect(!bridge.controller.isActive)
        #expect(sessions.made.last?.content == nil)
        await #expect(throws: NowPlayingCommandError.noPlayer) { try await bridge.controller.perform(.play) }
    }
}
