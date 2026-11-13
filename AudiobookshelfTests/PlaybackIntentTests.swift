import ABSAppModel
import ABSCore
import ABSPlayback
import Foundation
import Testing

@testable import Audiobookshelf

/// The shared playback intents (#86, #88) reach the app's player through ``PlaybackIntentRouter``
/// and ``PlaybackIntentHandler``. The mapping itself is tested in `PlaybackIntentPerformerTests`.
@MainActor @Suite(.serialized) struct PlaybackIntentTests {
    /// A sleep timer that records what it was asked to start.
    final class RecordingSleepTimer: SleepTimerStarting {
        var started: [SleepTimerMode] = []
        var accepts = true

        func start(_ mode: SleepTimerMode) -> Bool {
            started.append(mode)
            return accepts
        }
    }

    let playback: PreviewPlaybackControl
    let sleepTimer = RecordingSleepTimer()
    let settings: AppSettings

    init() {
        let suiteName = "PlaybackIntentTests"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        settings = AppSettings(defaults: defaults)
        settings.jumpForwardTime = 30
        settings.jumpBackwardsTime = 10
        playback = PreviewPlaybackControl(at: 4_000, playing: true)
    }

    /// Registers a handler over the test's player, run while `body` runs.
    func withHandler(_ body: () async throws -> Void) async rethrows {
        let timer = sleepTimer
        PlaybackIntentRouter.handler = PlaybackIntentHandler(
            playback: playback, settings: settings, sleepTimer: { timer })
        defer { PlaybackIntentRouter.handler = nil }
        try await body()
    }

    @Test func intentsFailWithoutAPlayer() async {
        PlaybackIntentRouter.handler = nil
        await #expect(throws: PlaybackIntentError.playerUnavailable) {
            _ = try await TogglePlaybackIntent().perform()
        }
        await #expect(throws: PlaybackIntentError.playerUnavailable) {
            _ = try await ResumeListeningIntent().perform()
        }
    }

    @Test func togglePausesAndResumesTheRegisteredPlayer() async throws {
        try await withHandler {
            _ = try await TogglePlaybackIntent().perform()
            #expect(!playback.isPlaybackRequested)
            _ = try await TogglePlaybackIntent().perform()
            #expect(playback.isPlaybackRequested)
        }
    }

    @Test func pauseAndResume() async throws {
        try await withHandler {
            _ = try await PauseIntent().perform()
            #expect(!playback.isPlaybackRequested)
            _ = try await ResumeListeningIntent().perform()
            #expect(playback.isPlaybackRequested)
        }
    }

    @Test func resumeWithNothingLoadedShowsNothingToResume() async {
        playback.stop(reason: .user)
        await withHandler {
            await #expect(throws: PlaybackIntentError.nothingToResume) {
                _ = try await ResumeListeningIntent().perform()
            }
        }
    }

    /// An intent can launch the app with no scene to start the lifecycle, so the player is still
    /// unbound: each command waits for the handler's `ready`, which restores the saved item.
    @Test func commandsWaitUntilTheAppIsReady() async throws {
        let current = CurrentPlayback()
        let restored = playback
        restored.pause()
        PlaybackIntentRouter.handler = PlaybackIntentHandler(
            playback: current, settings: settings, ready: { current.bind(restored) })
        defer { PlaybackIntentRouter.handler = nil }
        // Unbound, `current` is idle and resuming would throw `nothingToResume`.
        _ = try await ResumeListeningIntent().perform()
        #expect(restored.isPlaybackRequested)
    }

    /// The play/pause control sets the state to end in: its value, not a toggle, so a second tap
    /// on a stale control can't undo the first.
    @Test func setPlayingPlaysOrPausesByItsValue() async throws {
        try await withHandler {
            _ = try await SetPlayingIntent(playing: false).perform()
            #expect(!playback.isPlaybackRequested)
            _ = try await SetPlayingIntent(playing: false).perform()
            #expect(!playback.isPlaybackRequested)
            _ = try await SetPlayingIntent(playing: true).perform()
            #expect(playback.isPlaybackRequested)
            _ = try await SetPlayingIntent(playing: true).perform()
            #expect(playback.isPlaybackRequested)
        }
    }

    @Test func setPlayingFailsWithoutAPlayer() async {
        PlaybackIntentRouter.handler = nil
        await #expect(throws: PlaybackIntentError.playerUnavailable) {
            _ = try await SetPlayingIntent(playing: true).perform()
        }
    }

    @Test func jumpUsesTheGivenSecondsOrTheUsersInterval() async throws {
        try await withHandler {
            _ = try await JumpIntent(direction: .forward, seconds: 45).perform()
            #expect(playback.currentTime == 4_045)
            _ = try await JumpIntent(direction: .backward).perform()
            #expect(playback.currentTime == 4_035)
            _ = try await JumpIntent(direction: .forward).perform()
            #expect(playback.currentTime == 4_065)
        }
    }

    @Test func sleepTimerStartsMinutesOrEndOfChapter() async throws {
        try await withHandler {
            _ = try await SetSleepTimerIntent(length: .minutes, minutes: 15).perform()
            _ = try await SetSleepTimerIntent(length: .endOfChapter).perform()
            #expect(sleepTimer.started == [.duration(900), .endOfChapter])
        }
    }

    @Test func sleepTimerToARefusedChapterEndShowsNoChapterEnd() async {
        sleepTimer.accepts = false
        await withHandler {
            await #expect(throws: PlaybackIntentError.noChapterEnd) {
                _ = try await SetSleepTimerIntent(length: .endOfChapter).perform()
            }
        }
    }

    @Test func speedIsClamped() async throws {
        try await withHandler {
            _ = try await SetPlaybackSpeedIntent(speed: 1.26).perform()
            #expect(playback.rate == 1.3)
            _ = try await SetPlaybackSpeedIntent(speed: 40).perform()
            #expect(playback.rate == 10)
        }
    }

    // MARK: Play item (#87)

    /// A book entity on `connectionID`'s account.
    func book(on connectionID: UUID) throws -> BookEntity {
        let summary = ItemSummary(id: "li_1", itemID: "li_1", kind: .book, title: "Book")
        return try #require(PlayableEntityRecord(summary: summary, connectionID: connectionID).flatMap(BookEntity.init))
    }

    @Test func playIntentsFailWithoutAPlayer() async throws {
        PlayableEntityRouter.handler = nil
        let book = try book(on: UUID())
        await #expect(throws: PlaybackIntentError.playerUnavailable) {
            _ = try await PlayBookIntent(book: book).perform()
        }
    }

    @Test func playIntentsRefuseAnItemOffTheSignedInAccount() async throws {
        // No library store: nobody is signed in, so no item is the signed-in account's.
        PlayableEntityRouter.handler = PlaybackIntentHandler(
            playback: playback, settings: settings, playItem: { PlayItemAction { _, _, _ in Issue.record("played") } })
        defer { PlayableEntityRouter.handler = nil }
        let book = try book(on: UUID())
        await #expect(throws: PlaybackIntentError.itemUnavailable) {
            _ = try await PlayBookIntent(book: book).perform()
        }
        #expect(await PlayableEntityRouter.entities(for: [book.id]).isEmpty)
    }
}
