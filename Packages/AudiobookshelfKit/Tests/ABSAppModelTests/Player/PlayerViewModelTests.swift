import ABSAPI
import ABSCore
import ABSData
import ABSPlayback
import Foundation
import Observation
import Testing

@testable import ABSAppModel

/// Runs `body` with a fake playback, settings backed by a fresh `UserDefaults` suite, and a view
/// model over both.
@MainActor
private func withPlayer(
    _ body: @MainActor (PlayerViewModel, FakePlaybackControl, AppSettings, UserDefaults) async throws -> Void
) async throws {
    let suiteName = "ABSAppModelTests.Player.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: defaults)
    let playback = FakePlaybackControl()
    try await body(PlayerViewModel(playback: playback, settings: settings), playback, settings, defaults)
}

/// Whether reading `read` inside observation tracking is invalidated by `change`.
@MainActor
private func invalidates(_ read: () -> Void, when change: () -> Void) -> Bool {
    let changed = Locked(false)
    withObservationTracking(read) { changed.value = true }
    change()
    return changed.value
}

private func restoredRecord(duration: Double? = 400) -> LastPlayedRecord {
    LastPlayedRecord(
        serverConnectionID: FakePlaybackControl.serverID, libraryItemID: "li_book", episodeID: nil, position: 120,
        duration: duration, timestamp: Date(timeIntervalSince1970: 0), title: "Restored", author: "Restored Author",
        coverPath: "/cover.jpg", chapterTitle: "Restored Chapter")
}

@MainActor
@Suite struct PlayerViewModelTests {
    // MARK: States

    @Test func idleHasNothingToShow() async throws {
        try await withPlayer { model, _, _, _ in
            #expect(!model.hasSession)
            #expect(model.title.isEmpty)
            #expect(model.author.isEmpty)
            #expect(model.chapterTitle == nil)
            #expect(model.coverKey == nil)
            #expect(model.elapsed == 0)
            #expect(model.remaining == 0)
            #expect(model.progress == 0)
            #expect(!model.hasPreviousChapter)
            #expect(!model.hasNextChapter)
            #expect(model.errorMessageKey == nil)
            #expect(!model.showsPause)
        }
    }

    @Test func restoredOnlyShowsTheRecordOverTheWholeItem() async throws {
        try await withPlayer { model, playback, settings, _ in
            settings.chapterTrack = true
            playback.restore(restoredRecord())
            #expect(model.hasSession)
            #expect(model.title == "Restored")
            #expect(model.author == "Restored Author")
            #expect(model.chapterTitle == "Restored Chapter")
            #expect(model.coverKey?.entityID == "li_book")
            // No timeline yet: whole-item times, and no chapter navigation.
            #expect(model.elapsed == 120)
            #expect(model.remaining == 280)
            #expect(model.progress == 0.3)
            #expect(!model.hasPreviousChapter)
            #expect(!model.hasNextChapter)
            await model.previousChapter()
            await model.nextChapter()
            #expect(playback.calls.isEmpty)
        }
    }

    @Test func loadedShowsTheSessionAndCurrentChapter() async throws {
        try await withPlayer { model, playback, _, _ in
            playback.load(FakePlaybackControl.bookSession(), at: 150, playing: true)
            #expect(model.title == "Dune")
            #expect(model.author == "Frank Herbert")
            #expect(model.chapterTitle == "Middle")
            #expect(model.coverKey?.updatedAt == 1_700_000_000_000)
            #expect(model.isPlaying)
            playback.currentTime = 300
            #expect(model.chapterTitle == "Ending")
        }
    }

    @Test func startingShowsTheSessionBeforeTheTimeline() async throws {
        try await withPlayer { model, playback, _, _ in
            playback.start(FakePlaybackControl.bookSession(), at: 150)
            #expect(model.hasSession)
            #expect(model.title == "Dune")
            #expect(model.author == "Frank Herbert")
            #expect(model.chapterTitle == "Middle")
            #expect(model.isBuffering)
            #expect(model.showsPause)
            #expect(model.progress == 0)
            #expect(!model.hasPreviousChapter)
            #expect(!model.hasNextChapter)
            playback.load(FakePlaybackControl.bookSession(), at: 150)
            #expect(model.chapterTitle == "Middle")
            #expect(model.hasPreviousChapter)
        }
    }

    // MARK: Transport

    @Test func playPauseFollowsThePlayIntent() async throws {
        try await withPlayer { model, playback, _, _ in
            playback.load(FakePlaybackControl.bookSession())
            // Starting or stalled: play is requested though nothing is playing yet.
            playback.isPlaybackRequested = true
            playback.isBuffering = true
            #expect(model.showsPause)
            #expect(!model.isPlaying)
            #expect(model.isBuffering)
            await model.togglePlayPause()
            #expect(playback.calls == [.pause])
            #expect(!model.showsPause)
            await model.togglePlayPause()
            #expect(playback.calls == [.pause, .resume(rewindingBy: nil)])
            #expect(model.showsPause)
        }
    }

    @Test func jumpsUseTheIntervalsFromSettings() async throws {
        try await withPlayer { model, playback, settings, _ in
            playback.load(FakePlaybackControl.bookSession(), at: 100)
            settings.jumpForwardTime = 30
            settings.jumpBackwardsTime = 15
            #expect(model.jumpForwardSeconds == 30)
            #expect(model.jumpBackwardSeconds == 15)
            await model.jumpForward()
            await model.jumpBackward()
            #expect(playback.calls == [.jump(30), .jump(-15)])
        }
    }

    @Test func setRateGoesToPlayback() async throws {
        try await withPlayer { model, playback, _, _ in
            model.setRate(1.5)
            #expect(playback.calls == [.setRate(1.5)])
            #expect(model.rate == 1.5)
        }
    }

    @Test func closeStopsForTheUser() async throws {
        try await withPlayer { model, playback, _, _ in
            playback.load(FakePlaybackControl.bookSession(), at: 150)
            model.beginScrub()
            model.close()
            #expect(playback.calls == [.stop(.user)])
            #expect(!model.hasSession)
            #expect(model.title.isEmpty)
            await model.endScrub()
            #expect(playback.calls == [.stop(.user)])
        }
    }

    // MARK: Chapters

    @Test(arguments: [
        // More than 3 s in restarts the chapter; otherwise the previous one; the first restarts.
        (150.0, 100.0), (103.5, 100.0), (102.0, 0.0), (1.0, 0.0), (252.0, 100.0), (399.0, 250.0),
    ])
    func previousChapter(from time: Double, to target: Double) async throws {
        try await withPlayer { model, playback, _, _ in
            playback.load(FakePlaybackControl.bookSession(), at: time)
            #expect(model.hasPreviousChapter)
            await model.previousChapter()
            #expect(playback.calls == [.seek(target)])
        }
    }

    @Test(arguments: [(0.0, 100.0), (150.0, 250.0), (99.995, 250.0)])
    func nextChapter(from time: Double, to target: Double) async throws {
        try await withPlayer { model, playback, _, _ in
            playback.load(FakePlaybackControl.bookSession(), at: time)
            #expect(model.hasNextChapter)
            await model.nextChapter()
            #expect(playback.calls == [.seek(target)])
        }
    }

    /// Just before "Ending" counts as inside it, like the legacy player's rounding.
    @Test(arguments: [300.0, 249.995])
    func noNextChapterInTheLastOne(at time: Double) async throws {
        try await withPlayer { model, playback, _, _ in
            playback.load(FakePlaybackControl.bookSession(), at: time)
            #expect(!model.hasNextChapter)
            await model.nextChapter()
            #expect(playback.calls.isEmpty)
        }
    }

    /// As the legacy player: previous restarts the item, next is unavailable.
    @Test func withoutChaptersPreviousRestartsTheItem() async throws {
        try await withPlayer { model, playback, _, _ in
            playback.load(FakePlaybackControl.bookSession(chapters: []), at: 150)
            #expect(model.hasPreviousChapter)
            #expect(!model.hasNextChapter)
            #expect(model.chapterTitle == nil)
            await model.nextChapter()
            await model.previousChapter()
            #expect(playback.calls == [.seek(0)])
        }
    }

    // MARK: Progress

    @Test func chapterTrackShowsTheChapterAndPersistsItsToggle() async throws {
        try await withPlayer { model, playback, settings, defaults in
            settings.chapterTrack = true
            playback.load(FakePlaybackControl.bookSession(), at: 175)
            #expect(model.usesChapterTrack)
            #expect(model.elapsed == 75)
            #expect(model.remaining == 75)
            #expect(model.progress == 0.5)

            model.toggleChapterTrack()
            #expect(!settings.chapterTrack)
            #expect(defaults.object(forKey: AppSettings.Key.chapterTrack.rawValue) as? Bool == false)
            #expect(!model.usesChapterTrack)
            #expect(model.elapsed == 175)
            #expect(model.remaining == 225)
            #expect(model.progress == 0.4375)
        }
    }

    @Test func chapterTrackFallsBackToTheWholeItemWithoutAChapter() async throws {
        try await withPlayer { model, playback, settings, _ in
            settings.chapterTrack = true
            playback.load(FakePlaybackControl.bookSession(chapters: []), at: 100)
            #expect(model.elapsed == 100)
            #expect(model.remaining == 300)
            #expect(model.progress == 0.25)
        }
    }

    @Test func remainingAtRateIsWallClockTime() async throws {
        try await withPlayer { model, playback, settings, _ in
            settings.chapterTrack = false
            playback.load(FakePlaybackControl.bookSession(), at: 100)
            #expect(model.remainingAtRate == 300)
            playback.rate = 1.5
            #expect(model.remaining == 300)
            #expect(model.remainingAtRate == 200)
            playback.rate = 0
            #expect(model.remainingAtRate == 300)
            playback.rate = .nan
            #expect(model.remainingAtRate == 300)
        }
    }

    // MARK: Scrubbing

    @Test func scrubbingIgnoresTicksAndSeeksOnce() async throws {
        try await withPlayer { model, playback, settings, _ in
            settings.chapterTrack = true
            playback.load(FakePlaybackControl.bookSession(), at: 150, playing: true)
            model.beginScrub()
            #expect(model.progress == 50.0 / 150)
            model.scrub(to: 0.5)
            #expect(model.elapsed == 75)
            playback.currentTime = 160  // A tick.
            #expect(model.elapsed == 75)
            #expect(model.progress == 0.5)
            model.scrub(to: 0.8)
            playback.currentTime = 170
            #expect(model.elapsed == 120)
            #expect(playback.calls.isEmpty)

            await model.endScrub()
            #expect(playback.calls == [.seek(220)])
            playback.currentTime = 230
            #expect(model.elapsed == 130)
            await model.endScrub()
            #expect(playback.calls == [.seek(220)])
        }
    }

    @Test func scrubStaysInTheChapterItBeganIn() async throws {
        try await withPlayer { model, playback, settings, _ in
            settings.chapterTrack = true
            playback.load(FakePlaybackControl.bookSession(), at: 150)
            model.scrub(to: 2)  // Begins implicitly; clamped to the chapter's end.
            #expect(model.progress == 1)
            await model.endScrub()
            #expect(playback.calls == [.seek(250)])
        }
    }

    @Test func scrubOverTheWholeItem() async throws {
        try await withPlayer { model, playback, settings, _ in
            settings.chapterTrack = false
            playback.load(FakePlaybackControl.bookSession(), at: 150)
            model.beginScrub()
            model.scrub(to: 0.25)
            #expect(model.elapsed == 100)
            #expect(model.remaining == 300)
            await model.endScrub()
            #expect(playback.calls == [.seek(100)])
        }
    }

    @Test func scrubForAnotherItemIsDropped() async throws {
        try await withPlayer { model, playback, _, _ in
            playback.load(FakePlaybackControl.bookSession(), at: 150)
            model.beginScrub()
            model.scrub(to: 0.9)
            playback.load(FakePlaybackControl.bookSession(item: "li_other"), at: 10)
            #expect(model.elapsed == 10)
            await model.endScrub()
            #expect(playback.calls.isEmpty)
        }
    }

    @Test func scrubWithoutMovingDoesNotSeek() async throws {
        try await withPlayer { model, playback, _, _ in
            playback.load(FakePlaybackControl.bookSession(), at: 150)
            model.beginScrub()
            await model.endScrub()
            #expect(playback.calls.isEmpty)
        }
    }

    /// An unloaded item of unknown duration, or one still starting, has an empty range: a scrub
    /// there must not seek, which would replace the resume position with 0.
    @Test func scrubOnAnEmptyRangeDoesNotSeek() async throws {
        try await withPlayer { model, playback, _, _ in
            playback.restore(restoredRecord(duration: nil))
            model.beginScrub()
            model.scrub(to: 0.5)
            await model.endScrub()
            model.scrub(to: 0.5)
            await model.endScrub()
            playback.start(FakePlaybackControl.bookSession(), at: 120)
            model.beginScrub()
            model.scrub(to: 0.5)
            await model.endScrub()
            #expect(playback.calls.isEmpty)
            #expect(model.elapsed == 0)
        }
    }

    /// The same item loading (session set, restored record cleared) keeps a scrub begun while it
    /// was restored, over the range fixed when it began.
    @Test func aScrubSurvivesTheSameItemLoading() async throws {
        try await withPlayer { model, playback, _, _ in
            playback.restore(restoredRecord())
            model.beginScrub()
            model.scrub(to: 0.5)
            playback.start(FakePlaybackControl.bookSession(), at: 120)
            #expect(model.elapsed == 200)
            playback.load(FakePlaybackControl.bookSession(), at: 120)
            #expect(model.elapsed == 200)
            await model.endScrub()
            #expect(playback.calls == [.seek(200)])
        }
    }

    @Test func aScrubDoesNotSurviveTheItemClosing() async throws {
        try await withPlayer { model, playback, settings, _ in
            settings.chapterTrack = true
            playback.load(FakePlaybackControl.bookSession(), at: 150)
            model.beginScrub()
            model.scrub(to: 0.9)
            playback.stop(reason: .user)
            playback.load(FakePlaybackControl.bookSession(), at: 10)
            #expect(model.elapsed == 10)
            playback.currentTime = 20
            #expect(model.elapsed == 20)
            await model.endScrub()
            #expect(playback.calls == [.stop(.user)])
            // A new scrub starts from the current chapter, "Opening".
            model.scrub(to: 0.5)
            await model.endScrub()
            #expect(playback.calls == [.stop(.user), .seek(50)])
        }
    }

    @Test func beginScrubNeedsAnItem() async throws {
        try await withPlayer { model, playback, _, _ in
            model.beginScrub()
            model.scrub(to: 0.5)
            await model.endScrub()
            #expect(playback.calls.isEmpty)
        }
    }

    // MARK: Errors

    @Test(arguments: [
        (
            PlaybackCoordinatorError.streamingNeedsConfirmation(.cellular, key: FakePlaybackControl.key()),
            PlayerErrorMessage.streamingNeedsConfirmation
        ),
        (.streamingNotAllowed(.lowDataMode, key: FakePlaybackControl.key()), .streamingNotAllowed),
        (.sessionStartFailed(.timedOut), .sessionStartFailed),
        (.streamUnavailable(.missingAccessToken), .streamUnavailable),
        (.engine(.emptyTimeline), .playbackFailed),
        (.unexpected("boom"), .playbackFailed),
    ])
    func errorMapsToAMessage(error: PlaybackCoordinatorError, message: PlayerErrorMessage) async throws {
        try await withPlayer { model, playback, _, _ in
            playback.error = error
            #expect(model.errorMessageKey == message)
            playback.error = nil
            #expect(model.errorMessageKey == nil)
        }
    }

    // MARK: Retained text

    @Test func textIsKeptWhenTheSessionDrops() async throws {
        try await withPlayer { model, playback, _, _ in
            playback.load(FakePlaybackControl.bookSession(), at: 150)
            #expect(model.title == "Dune")
            #expect(model.chapterTitle == "Middle")
            // A failed reload: same item, no session or timeline.
            playback.phase = .unloaded
            playback.session = nil
            playback.timeline = nil
            #expect(model.title == "Dune")
            #expect(model.author == "Frank Herbert")
            #expect(model.chapterTitle == "Middle")
            #expect(model.coverKey?.updatedAt == 1_700_000_000_000)
        }
    }

    @Test func textIsKeptEvenIfNoViewReadIt() async throws {
        try await withPlayer { model, playback, _, _ in
            playback.load(FakePlaybackControl.bookSession(), at: 150)
            playback.currentTime = 300
            playback.phase = .unloaded
            playback.session = nil
            playback.timeline = nil
            #expect(model.title == "Dune")
            // The chapter follows the position in the dropped session's chapters.
            #expect(model.chapterTitle == "Ending")
            playback.currentTime = 50
            #expect(model.chapterTitle == "Opening")
        }
    }

    @Test func liveTextWinsOverTheRestoredRecordAfterAFailedLoad() async throws {
        try await withPlayer { model, playback, _, _ in
            playback.restore(restoredRecord())
            #expect(model.title == "Restored")
            playback.load(FakePlaybackControl.bookSession(), at: 120)
            #expect(model.title == "Dune")
            playback.phase = .unloaded
            playback.session = nil
            playback.timeline = nil
            playback.restoredRecord = restoredRecord()
            #expect(model.title == "Dune")
        }
    }

    @Test func restoredCoverIsKeptWhenItsSessionStarts() async throws {
        try await withPlayer { model, playback, _, _ in
            var record = restoredRecord()
            record.coverPath = "/metadata/items/li_book/cover.jpg"
            playback.restore(record)
            let restoredCover = model.coverKey
            #expect(restoredCover?.updatedAt == nil)
            playback.load(FakePlaybackControl.bookSession(), at: 120)
            #expect(model.title == "Dune")
            #expect(model.coverKey == restoredCover)
            // A restart is a new session, which gets the dated key.
            playback.start(FakePlaybackControl.bookSession(id: "sess_2"), at: 120)
            #expect(model.coverKey?.updatedAt == 1_700_000_000_000)
        }
    }

    @Test func anotherItemDoesNotShowTheLastText() async throws {
        try await withPlayer { model, playback, _, _ in
            playback.load(FakePlaybackControl.bookSession(), at: 150)
            #expect(model.title == "Dune")
            playback.phase = .starting
            playback.mediaKey = FakePlaybackControl.key(item: "li_next")
            playback.session = nil
            playback.timeline = nil
            #expect(model.title.isEmpty)
            #expect(model.coverKey == nil)
            #expect(model.chapterTitle == nil)
        }
    }

    // MARK: Observation

    @Test func observationFollowsPlaybackAndSettings() async throws {
        try await withPlayer { model, playback, settings, _ in
            playback.load(FakePlaybackControl.bookSession(), at: 150)
            #expect(invalidates({ _ = model.progress }, when: { playback.currentTime = 151 }))
            #expect(invalidates({ _ = model.elapsed }, when: { settings.chapterTrack.toggle() }))
            #expect(invalidates({ _ = model.showsPause }, when: { playback.isPlaybackRequested = true }))
            #expect(invalidates({ _ = model.rate }, when: { playback.rate = 2 }))
            #expect(invalidates({ _ = model.jumpForwardSeconds }, when: { settings.jumpForwardTime = 60 }))
            #expect(invalidates({ _ = model.title }, when: { playback.session = nil }))
            #expect(invalidates({ _ = model.hasSession }, when: { playback.phase = .idle }))
            #expect(invalidates({ _ = model.errorMessageKey }, when: { playback.error = .unexpected("x") }))
        }
    }

    @Test func scrubbingStopsTickInvalidation() async throws {
        try await withPlayer { model, playback, _, _ in
            playback.load(FakePlaybackControl.bookSession(), at: 150)
            model.beginScrub()
            #expect(!invalidates({ _ = model.progress }, when: { playback.currentTime = 151 }))
            #expect(invalidates({ _ = model.progress }, when: { model.scrub(to: 0.1) }))
            await model.endScrub()
            #expect(invalidates({ _ = model.progress }, when: { playback.currentTime = 152 }))
        }
    }
}
