import ABSData
import AppIntents
import Foundation
import NowPlaying
import Testing
import _NowPlaying_AppIntents

@testable import ABSPlayback

@MainActor
@Suite struct NowPlayingControllerTests {
    typealias F = NowPlayingFixtures

    // MARK: Mapping

    @Test func mapsBookStateToBookContentAndSnapshot() throws {
        let h = NowPlayingHarness()
        h.controller.update(F.book())
        let session = try h.session

        let book = try #require(session.book)
        #expect(book.id == F.bookKey.rawValue)
        #expect(book.title == "The Book")
        #expect(book.authorName == "An Author")
        #expect(book.narratorName == "A Narrator")
        #expect(book.duration?.finiteValue == 6000)
        #expect(book.chapter?.current == 3)
        #expect(book.chapter?.total == 10)
        #expect(book.artwork == nil)
        #expect(book.appEntityIdentifiers == [EntityIdentifier(for: TestBookEntity.self, identifier: "li_book")])
        #expect(h.entityCalls.keys == [F.bookKey])

        #expect(
            session.snapshot
                == MediaPlaybackSnapshot(state: .playing(rate: 1.5), elapsedTime: 700, timestamp: h.clock.now))
        #expect(session.contents.count == 1)
        #expect(session.snapshots.count == 1)
        #expect(session.commandUpdates.count == 1)
    }

    @Test func chapterTrackShowsChapterTitleAndChapterRelativeTimes() throws {
        let h = NowPlayingHarness(settings: NowPlayingSettings(chapterTrack: true))
        h.controller.update(F.book(elapsed: 700))
        let session = try h.session

        let book = try #require(session.book)
        #expect(book.title == "Chapter Three")
        #expect(book.duration?.finiteValue == 600)
        #expect(book.chapter?.current == 3)
        #expect(
            session.snapshot
                == MediaPlaybackSnapshot(state: .playing(rate: 1.5), elapsedTime: 100, timestamp: h.clock.now))
    }

    @Test func chapterTrackWithoutChapterFallsBackToTheWholeItem() throws {
        let h = NowPlayingHarness(settings: NowPlayingSettings(chapterTrack: true))
        h.controller.update(F.book(elapsed: 700, chapter: nil))
        let session = try h.session

        let book = try #require(session.book)
        #expect(book.title == "The Book")
        #expect(book.duration?.finiteValue == 6000)
        #expect(book.chapter == nil)
        #expect(
            session.snapshot
                == MediaPlaybackSnapshot(state: .playing(rate: 1.5), elapsedTime: 700, timestamp: h.clock.now))
    }

    @Test func mapsEpisodeStateToPodcastContent() throws {
        let h = NowPlayingHarness()
        let release = Date(timeIntervalSince1970: 1_700_000_000)
        h.controller.update(
            NowPlayingState(
                key: F.episodeKey, title: "Episode 1", author: "The Show", narrator: "ignored",
                releaseDate: release, duration: 1800, elapsed: 60, rate: 1, isPlaying: false))
        let session = try h.session

        let podcast = try #require(session.podcast)
        #expect(podcast.id == F.episodeKey.rawValue)
        #expect(podcast.episodeTitle == "Episode 1")
        #expect(podcast.showName == "The Show")
        #expect(podcast.releaseDate == release)
        #expect(podcast.duration?.finiteValue == 1800)
        #expect(podcast.type == .audio)
        #expect(podcast.appEntityIdentifiers == [EntityIdentifier(for: TestBookEntity.self, identifier: "li_show")])
        #expect(session.snapshot == MediaPlaybackSnapshot(state: .paused, elapsedTime: 60, timestamp: h.clock.now))
    }

    @Test(arguments: [0, -1, Double.nan, Double.infinity])
    func unknownDurationIsLeftOut(_ duration: Double) throws {
        let h = NowPlayingHarness()
        var state = F.book(chapter: nil)
        state.duration = duration
        h.controller.update(state)
        #expect(try #require(try h.session.book).duration == nil)
    }

    @Test func requestsApplicationPrimaryOnceWhenTheSessionStarts() async throws {
        let h = NowPlayingHarness()
        h.controller.update(F.book())
        await h.controller.activationTask?.value
        h.controller.update(F.book(isPlaying: false))
        await h.controller.activationTask?.value
        #expect(try h.session.applicationPrimaryRequests == 1)
        #expect(h.sessions.made.count == 1)

        await h.controller.requestSystemPrimary()
        #expect(try h.session.systemPrimaryRequests == 1)
    }

    // MARK: Commands

    @Test func routesCommandsToTheHandler() async throws {
        let h = NowPlayingHarness()
        h.controller.update(F.book())

        for command: NowPlayingCommand in [.play, .pause, .togglePlayPause, .skipForward(15), .skipBackward(5)] {
            try await h.controller.perform(command)
        }
        try await h.controller.perform(.changeRate(1.25))
        #expect(h.handler.calls == [.play, .pause, .toggle, .skipForward(15), .skipBackward(5), .rate(1.25)])
    }

    @Test func offersTheUsersIntervalsAndRates() throws {
        let h = NowPlayingHarness(
            settings: NowPlayingSettings(jumpForwardTime: 30, jumpBackwardsTime: 15, chapterTrack: false))
        h.controller.update(F.book())
        #expect(
            h.controller.publishedCommands
                == NowPlayingCommandSet(
                    skipForwardInterval: 30, skipBackwardInterval: 15,
                    supportedRates: [0.5, 0.75, 1.0, 1.25, 1.5, 2], canSeek: false))
    }

    @Test func nextAndPreviousTrackJumpByTheUsersIntervals() async throws {
        let h = NowPlayingHarness(
            settings: NowPlayingSettings(jumpForwardTime: 30, jumpBackwardsTime: 15, chapterTrack: false))
        h.controller.update(F.book())

        try await h.controller.perform(.nextTrack)
        try await h.controller.perform(.previousTrack)
        #expect(h.handler.calls == [.skipForward(30), .skipBackward(15)])

        h.controller.settings.jumpForwardTime = 45
        h.controller.settings.jumpBackwardsTime = 20
        try await h.controller.perform(.nextTrack)
        try await h.controller.perform(.previousTrack)
        #expect(Array(h.handler.calls.suffix(2)) == [.skipForward(45), .skipBackward(20)])
        #expect(h.controller.publishedCommands?.skipForwardInterval == 45)
        #expect(h.controller.publishedCommands?.skipBackwardInterval == 20)
        #expect(try h.session.commandUpdates.count == 3)
    }

    @Test func commandsWithoutAPlayerFail() async throws {
        let h = NowPlayingHarness()
        await #expect(throws: NowPlayingCommandError.noPlayer) { try await h.controller.perform(.play) }
        h.controller.update(F.book())
        h.controller.commandHandler = nil
        await #expect(throws: NowPlayingCommandError.noPlayer) { try await h.controller.perform(.play) }
    }

    // MARK: Seeking

    @Test func seekIsOfferedOnlyWhenAllowed() async throws {
        let h = NowPlayingHarness()
        h.controller.update(F.book())
        #expect(h.controller.publishedCommands?.canSeek == false)
        await #expect(throws: NowPlayingCommandError.seekingDisabled) {
            try await h.controller.perform(.seek(100))
        }
        #expect(h.handler.calls.isEmpty)

        h.controller.settings.allowSeekingOnMediaControls = true
        #expect(h.controller.publishedCommands?.canSeek == true)
        #expect(try h.session.commandUpdates.count == 2)
        try await h.controller.perform(.seek(100))
        #expect(h.handler.calls == [.seek(100)])

        h.controller.settings.allowSeekingOnMediaControls = false
        #expect(h.controller.publishedCommands?.canSeek == false)
        #expect(try h.session.commandUpdates.count == 3)
        await #expect(throws: NowPlayingCommandError.seekingDisabled) {
            try await h.controller.perform(.seek(200))
        }
        #expect(h.handler.calls == [.seek(100)])
    }

    @Test func seekInChapterTrackModeIsRelativeToTheChapter() async throws {
        let h = NowPlayingHarness(
            settings: NowPlayingSettings(allowSeekingOnMediaControls: true, chapterTrack: true))
        h.controller.update(F.book())
        try await h.controller.perform(.seek(100))
        try await h.controller.perform(.seek(9999))
        #expect(h.handler.calls == [.seek(700), .seek(1200)])
    }

    @Test func seekIsClampedToTheItem() async throws {
        let h = NowPlayingHarness(settings: NowPlayingSettings(allowSeekingOnMediaControls: true, chapterTrack: false))
        h.controller.update(F.book())
        try await h.controller.perform(.seek(-5))
        try await h.controller.perform(.seek(7000))
        #expect(h.handler.calls == [.seek(0), .seek(6000)])
    }

    // MARK: Redundant updates

    @Test func identicalStateAndSettingsPublishNothing() throws {
        let h = NowPlayingHarness()
        h.controller.update(F.book(isPlaying: false))
        h.controller.update(F.book(isPlaying: false))
        h.controller.settings = NowPlayingSettings(chapterTrack: false)
        let session = try h.session
        #expect(session.contents.count == 1)
        #expect(session.snapshots.count == 1)
        #expect(session.commandUpdates.count == 1)
        #expect(h.entityCalls.keys.count == 1)
    }

    @Test func ticksThatMatchExtrapolationPublishNothing() throws {
        let h = NowPlayingHarness()
        h.controller.update(F.book(elapsed: 700, rate: 1.5))
        for _ in 0..<10 {
            h.clock.advance(by: 1)
            h.controller.update(F.book(elapsed: 700 + 1.5 * (h.clock.now.timeIntervalSince1970 - 1_800_000_000)))
        }
        // Small drift stays within the tolerance.
        h.controller.update(F.book(elapsed: 715.5))
        let session = try h.session
        #expect(session.snapshots.count == 1)
        #expect(session.contents.count == 1)
    }

    @Test func seekRateAndPlayStateChangesPushElapsedTime() throws {
        let h = NowPlayingHarness()
        h.controller.update(F.book(elapsed: 700, rate: 1))
        let session = try h.session

        h.clock.advance(by: 2)
        h.controller.update(F.book(elapsed: 760, rate: 1))  // jump / seek
        #expect(
            session.snapshot
                == MediaPlaybackSnapshot(state: .playing(rate: 1), elapsedTime: 760, timestamp: h.clock.now))

        h.controller.update(F.book(elapsed: 760, rate: 2))  // rate
        #expect(
            session.snapshot
                == MediaPlaybackSnapshot(state: .playing(rate: 2), elapsedTime: 760, timestamp: h.clock.now))

        h.clock.advance(by: 1)
        h.controller.update(F.book(elapsed: 762, rate: 2, isPlaying: false))  // pause
        #expect(session.snapshot == MediaPlaybackSnapshot(state: .paused, elapsedTime: 762, timestamp: h.clock.now))

        h.clock.advance(by: 10)
        h.controller.update(F.book(elapsed: 762, rate: 2, isPlaying: false))  // still paused: nothing
        h.controller.update(F.book(elapsed: 500, rate: 2, isPlaying: false))  // seek while paused
        #expect(session.snapshot == MediaPlaybackSnapshot(state: .paused, elapsedTime: 500, timestamp: h.clock.now))
        #expect(session.snapshots.count == 5)
        #expect(session.contents.count == 1)
    }

    @Test func chapterChangeRepublishesContentAndElapsedTime() throws {
        let h = NowPlayingHarness(settings: NowPlayingSettings(chapterTrack: true))
        h.controller.update(F.book(elapsed: 1199, rate: 1))
        let session = try h.session

        h.clock.advance(by: 1)
        let next = NowPlayingState.Chapter(
            title: "Chapter Four", index: 3, count: 10, range: TimelineRange(start: 1200, end: 1500))
        h.controller.update(F.book(elapsed: 1200, rate: 1, chapter: next))
        #expect(session.book?.title == "Chapter Four")
        #expect(session.book?.chapter?.current == 4)
        #expect(session.book?.duration?.finiteValue == 300)
        #expect(
            session.snapshot == MediaPlaybackSnapshot(state: .playing(rate: 1), elapsedTime: 0, timestamp: h.clock.now))
        #expect(session.contents.count == 2)
        #expect(session.snapshots.count == 2)
    }

    @Test func chapterTrackSettingChangeRepublishesMetadata() throws {
        let h = NowPlayingHarness()
        h.controller.update(F.book(elapsed: 700))
        let session = try h.session
        #expect(session.book?.title == "The Book")

        h.controller.settings.chapterTrack = true
        #expect(session.book?.title == "Chapter Three")
        #expect(
            session.snapshot
                == MediaPlaybackSnapshot(state: .playing(rate: 1.5), elapsedTime: 100, timestamp: h.clock.now))
        #expect(session.commandUpdates.count == 1)
    }

    // MARK: Artwork

    @Test func artworkLoadsAsynchronouslyAndIsAddedToTheContent() async throws {
        let gate = ArtworkGate()
        let h = NowPlayingHarness(artwork: { await gate.load($0) })
        h.controller.update(F.book(artworkKey: "cover-1"))
        let session = try h.session
        #expect(session.book?.artwork == nil)

        await gate.resolve("cover-1", with: Data([1, 2, 3]))
        await h.controller.artworkTask?.value
        #expect(session.book?.artwork?.id == "cover-1")
        #expect(session.contents.count == 2)
        // The artwork arriving doesn't move elapsed time.
        #expect(session.snapshots.count == 1)

        // Same item and key: no reload.
        h.controller.update(F.book(artworkKey: "cover-1"))
        #expect(session.contents.count == 2)
    }

    @Test func staleArtworkIsIgnoredAfterTheItemChanges() async throws {
        let gate = ArtworkGate()
        let h = NowPlayingHarness(artwork: { await gate.load($0) })
        h.controller.update(F.book(artworkKey: "cover-1"))
        let firstLoad = try #require(h.controller.artworkTask)

        var other = F.book(artworkKey: "cover-2")
        other.key = F.otherBookKey
        other.title = "Other Book"
        h.controller.update(other)
        let secondLoad = try #require(h.controller.artworkTask)

        let session = try h.session
        let published = session.contents.count
        await gate.resolve("cover-1", with: Data([1]))
        await firstLoad.value
        #expect(session.contents.count == published)
        #expect(session.book?.title == "Other Book")
        #expect(session.book?.artwork == nil)

        await gate.resolve("cover-2", with: Data([2]))
        await secondLoad.value
        #expect(session.book?.id == F.otherBookKey.rawValue)
        #expect(session.book?.artwork?.id == "cover-2")
        #expect(h.entityCalls.keys == [F.bookKey, F.otherBookKey])
    }

    @Test func missingArtworkLeavesContentUnchanged() async throws {
        let h = NowPlayingHarness(artwork: { _ in nil })
        h.controller.update(F.book(artworkKey: "cover-1"))
        await h.controller.artworkTask?.value
        #expect(try h.session.book?.artwork == nil)
        #expect(try h.session.contents.count == 1)
    }

    // MARK: Clearing

    @Test func clearRemovesEverythingAndEndsTheSession() async throws {
        let gate = ArtworkGate()
        let h = NowPlayingHarness(artwork: { await gate.load($0) })
        h.controller.update(F.book(artworkKey: "cover-1"))
        let pendingLoad = try #require(h.controller.artworkTask)
        let session = try h.session

        h.controller.clear()
        #expect(!h.controller.isActive)
        #expect(h.controller.state == nil)
        #expect(session.content == nil)
        #expect(session.snapshot == nil)
        #expect(session.commandUpdates.last?.isEmpty == true)
        await #expect(throws: NowPlayingCommandError.noPlayer) { try await h.controller.perform(.play) }

        // A load that finishes after the clear doesn't republish anything.
        await gate.resolve("cover-1", with: Data([1]))
        await pendingLoad.value
        #expect(session.contents.count == 2)

        // The next item starts a new session.
        h.controller.update(F.book())
        await h.controller.activationTask?.value
        #expect(h.sessions.made.count == 2)
        #expect(try h.session.applicationPrimaryRequests == 1)
        #expect(try h.session.book?.id == F.bookKey.rawValue)
    }

    @Test func updatingWithNilClears() throws {
        let h = NowPlayingHarness()
        h.controller.update(F.book())
        let session = try h.session
        h.controller.update(nil)
        #expect(!h.controller.isActive)
        #expect(session.content == nil)
        #expect(session.snapshot == nil)

        h.controller.update(nil)
        #expect(session.contents.count == 2)
    }
}
