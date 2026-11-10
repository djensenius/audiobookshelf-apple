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
    let settings = ObservableNowPlayingSettings(
        NowPlayingSettings(jumpForwardTime: 30, jumpBackwardsTime: 15, chapterTrack: false))
    let sessions = NowPlayingHarness.SessionLog()
    let covers = CoverCalls()
    let bridge: NowPlayingBridge

    var coordinator: PlaybackCoordinator { h.coordinator }
    var controller: NowPlayingController { bridge.controller }
    var session: FakeNowPlayingSession {
        get throws { try #require(sessions.made.last) }
    }

    init(_ h: CoordinatorHarness? = nil) throws {
        let h = try h ?? CoordinatorHarness()
        self.h = h
        bridge = Self.makeBridge(h, settings: settings, sessions: sessions, covers: covers)
    }

    static func makeBridge(
        _ h: CoordinatorHarness, settings: ObservableNowPlayingSettings, sessions: NowPlayingHarness.SessionLog,
        covers: CoverCalls
    ) -> NowPlayingBridge {
        let clock = h.clock
        return NowPlayingBridge(
            coordinator: h.coordinator, settings: { settings.value },
            coverProvider: { cover in
                covers.record(cover)
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

    func snapshot(_ state: MediaPlaybackSnapshot.PlaybackState, at elapsed: Double) -> MediaPlaybackSnapshot {
        MediaPlaybackSnapshot(state: state, elapsedTime: elapsed, timestamp: h.clock.now)
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

        // The next refresh notices and ends the session.
        bridge.refresh()
        #expect(bridge.isInvalidated)
        #expect(!bridge.controller.isActive)
        #expect(sessions.made.last?.content == nil)
        await #expect(throws: NowPlayingCommandError.noPlayer) { try await bridge.controller.perform(.play) }
    }
}
