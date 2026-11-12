import ABSCore
import Foundation
import Testing

@testable import ABSAppModel
@testable import ABSPlayback

/// A player and a sleep timer over one fake playback, as the coordinator serves both in the app,
/// with settings in a fresh suite. The timer's clock only moves when a test advances it.
@MainActor
private final class Harness {
    let suiteName = "ABSAppModelTests.PlaybackCommands.\(UUID().uuidString)"
    let defaults: UserDefaults
    let playback = FakePlaybackControl()
    let player: PlayerViewModel
    let timer: SleepTimer

    init(options: SleepTimerOptions = SleepTimerOptions(fadesOut: false)) throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        player = PlayerViewModel(playback: playback, settings: AppSettings(defaults: defaults))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        timer = SleepTimer(
            control: playback, options: options, clock: ManualClock(), calendar: utc, tickInterval: .seconds(10))
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// The menu's model over the player and the timer, and `bookmarks` when given.
    func model(bookmarks: BookmarkStore? = nil) -> PlaybackCommandsModel {
        PlaybackCommandsModel(player: player, sleepTimer: timer, bookmarks: bookmarks)
    }

    /// Loads the fake book (chapters 0–100, 100–250, 250–400) at `time`.
    func load(at time: Double = 120, playing: Bool = false) {
        playback.load(FakePlaybackControl.bookSession(), at: time, playing: playing)
    }
}

/// The submenu's commands, with one of its presets.
private let sleepTimerCommands: [SleepTimerCommand] = [.minutes(15), .endOfChapter, .cancel]

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PlaybackCommandsModelTests {
    @Test func nothingEnabledWithoutPlayer() async {
        let model = PlaybackCommandsModel(player: nil)
        for command in PlaybackCommand.allCases {
            #expect(!model.isEnabled(command), "\(command)")
            await model.perform(command)
        }
        for command in sleepTimerCommands {
            #expect(!model.isEnabled(command), "\(command)")
            model.perform(command)
        }
        #expect(!model.showsPause)
    }

    @Test func nothingEnabledWithoutItem() async throws {
        let harness = try Harness()
        let model = harness.model()
        for command in PlaybackCommand.allCases {
            #expect(!model.isEnabled(command), "\(command)")
            await model.perform(command)
        }
        for command in sleepTimerCommands {
            #expect(!model.isEnabled(command), "\(command)")
            model.perform(command)
        }
        #expect(harness.playback.calls.isEmpty)
        #expect(harness.timer.mode == nil)
    }

    @Test func transportEnabledWithItem() async throws {
        let harness = try Harness()
        let model = harness.model()
        harness.load(at: 120)
        #expect(model.isEnabled(.playPause))
        #expect(model.isEnabled(.jumpBackward))
        #expect(model.isEnabled(.jumpForward))
        #expect(!model.showsPause)

        await model.perform(.playPause)
        #expect(model.showsPause)
        await model.perform(.playPause)
        await model.perform(.jumpBackward)
        await model.perform(.jumpForward)
        #expect(harness.playback.calls == [.resume(rewindingBy: nil), .pause, .jump(-10), .jump(10)])
    }

    @Test func transportEnabledWhileStarting() throws {
        let harness = try Harness()
        let model = harness.model()
        // The coordinator's `.starting` phase: a session but no timeline yet.
        harness.playback.start(FakePlaybackControl.bookSession(), at: 120)
        #expect(model.isEnabled(.playPause))
        #expect(model.isEnabled(.jumpForward))
        #expect(!model.isEnabled(.previousChapter), "Nothing to seek in yet")
        #expect(!model.isEnabled(.nextChapter))
    }

    @Test func chaptersFollowPosition() async throws {
        let harness = try Harness()
        let model = harness.model()
        harness.load(at: 120)
        #expect(model.isEnabled(.previousChapter))
        #expect(model.isEnabled(.nextChapter))

        await model.perform(.nextChapter)
        #expect(harness.playback.currentTime == 250)
        #expect(!model.isEnabled(.nextChapter), "The last chapter")
        await model.perform(.nextChapter)
        #expect(harness.playback.calls == [.seek(250)], "A disabled command does nothing")

        await model.perform(.previousChapter)
        #expect(harness.playback.calls == [.seek(250), .seek(100)])
    }

    @Test func previousChapterNeedsSomewhereToGo() async throws {
        let harness = try Harness()
        let model = harness.model()
        // At the start of the first chapter it would seek to where playback is.
        harness.load(at: 0)
        #expect(!model.isEnabled(.previousChapter))
        await model.perform(.previousChapter)
        #expect(harness.playback.calls.isEmpty)

        // Anywhere else in the first chapter, even within the restart threshold, it restarts it.
        harness.load(at: 2)
        #expect(model.isEnabled(.previousChapter))
        harness.load(at: 50)
        #expect(model.isEnabled(.previousChapter))
        await model.perform(.previousChapter)
        #expect(harness.playback.calls == [.seek(0)])
        #expect(!model.isEnabled(.previousChapter), "Back at the start")

        // At the start of a later chapter it goes to the previous one.
        harness.load(at: 100)
        #expect(model.isEnabled(.previousChapter))
        await model.perform(.previousChapter)
        #expect(harness.playback.calls == [.seek(0), .seek(0)])
    }

    @Test func speedStopsAtRangeEnds() async throws {
        let harness = try Harness()
        let model = harness.model()
        harness.load()
        #expect(model.isEnabled(.speedUp))
        #expect(model.isEnabled(.speedDown))

        await model.perform(.speedUp)
        #expect(harness.playback.rate == 1.1)
        await model.perform(.speedDown)
        #expect(harness.playback.rate == 1)

        harness.playback.rate = PlaybackSpeed.range.upperBound
        #expect(!model.isEnabled(.speedUp))
        #expect(model.isEnabled(.speedDown))
        harness.playback.rate = PlaybackSpeed.range.lowerBound
        #expect(model.isEnabled(.speedUp))
        #expect(!model.isEnabled(.speedDown))
        await model.perform(.speedDown)
        #expect(harness.playback.calls == [.setRate(1.1), .setRate(1)])
    }

    @Test func addBookmarkFollowsCreateBookmark() async throws {
        let harness = try Harness()
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        harness.load(at: 30.6)
        #expect(!harness.model().isEnabled(.addBookmark), "Without a store")

        let model = harness.model(bookmarks: store)
        #expect(!model.isEnabled(.addBookmark), "Before a load says which seconds have bookmarks")
        store.replaceAll(from: bookmarkUser([bookmark("li_book", 30)]))
        #expect(!model.isEnabled(.addBookmark), "One is at this second")

        harness.playback.currentTime = 31.2
        #expect(model.isEnabled(.addBookmark))
        var writes = service.writes.calls.makeAsyncIterator()
        let add = Task { await model.perform(.addBookmark) }
        let write = try #require(await writes.next())
        guard case .create(let itemID, let time, let title) = write.request else {
            Issue.record("Expected a create, got \(write.request)")
            return
        }
        #expect(itemID == "li_book")
        #expect(time == 31)
        #expect(!title.isEmpty, "The date and time, as for an empty title (D9)")
        write.reply.resume(returning: nil)
        #expect(await add.value == nil)
        #expect(store.bookmarks(itemID: "li_book").map(\.time) == [30, 31])
        #expect(!model.isEnabled(.addBookmark), "Now one is at this second")
    }

    @Test func addBookmarkReportsAFailedRequest() async throws {
        let harness = try Harness()
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        store.replaceAll(from: bookmarkUser([]))
        harness.load(at: 31)
        let model = harness.model(bookmarks: store)
        var writes = service.writes.calls.makeAsyncIterator()

        let rejected = Task { await model.perform(.addBookmark) }
        try #require(await writes.next()).reply.resume(throwing: BookmarkTestError.rejected)
        #expect(await rejected.value == .addBookmark)
        #expect(store.bookmarks(itemID: "li_book").isEmpty, "The store rolled it back")

        // Cancelling isn't failing, as in the bookmarks sheet.
        let cancelled = Task { await model.perform(.addBookmark) }
        try #require(await writes.next()).reply.resume(throwing: CancellationError())
        #expect(await cancelled.value == nil)
        #expect(store.bookmarks(itemID: "li_book").isEmpty)
    }

    @Test func addBookmarkWaitsForLoad() async throws {
        let harness = try Harness()
        let service = FakeBookmarkService()
        let store = try await makeBookmarkStore(service)
        // Answers any write, so one sent by mistake fails on `sentWrites` instead of hanging.
        let responder = Task {
            for await call in service.writes.calls {
                call.reply.resume(returning: nil)
            }
        }
        defer { responder.cancel() }
        harness.load(at: 31)

        // Until a load says which seconds have bookmarks, one at this second would look new (D10).
        await harness.model(bookmarks: store).perform(.addBookmark)
        #expect(service.sentWrites == 0)
        #expect(store.bookmarks(itemID: "li_book").isEmpty)
    }

    @Test func addBookmarkDisabledForPodcastEpisode() async throws {
        let harness = try Harness()
        let store = try await makeBookmarkStore(FakeBookmarkService())
        store.replaceAll(from: bookmarkUser([]))
        harness.playback.load(FakePlaybackControl.bookSession(item: "li_pod"), at: 5)
        harness.playback.mediaKey = FakePlaybackControl.key(item: "li_pod", episode: "ep_1")
        #expect(!harness.model(bookmarks: store).isEnabled(.addBookmark))
    }

    @Test func sleepTimerStartsWithItem() throws {
        let harness = try Harness()
        let model = harness.model()
        harness.load(at: 120, playing: true)
        #expect(model.isEnabled(.minutes(15)))
        #expect(model.isEnabled(.endOfChapter))
        #expect(!model.isEnabled(.cancel), "No timer runs")

        model.perform(.minutes(15))
        #expect(harness.timer.mode == .duration(900))
        #expect(model.isEnabled(.cancel))
        model.perform(.endOfChapter)
        #expect(harness.timer.mode == .endOfChapter)
        model.perform(.cancel)
        #expect(harness.timer.mode == nil)
    }

    @Test func sleepTimerDisabledWithoutTimer() throws {
        let harness = try Harness()
        let model = PlaybackCommandsModel(player: harness.player)
        harness.load()
        for command in sleepTimerCommands {
            #expect(!model.isEnabled(command), "\(command)")
        }
    }

    @Test func endOfChapterNeedsChapterPlaying() throws {
        let harness = try Harness()
        let model = harness.model()
        // The coordinator's `.starting` phase: a session but no timeline yet.
        harness.playback.start(FakePlaybackControl.bookSession(), at: 120)
        #expect(model.isEnabled(.minutes(15)))
        #expect(!model.isEnabled(.endOfChapter))
        model.perform(.endOfChapter)
        #expect(harness.timer.mode == nil)
    }

    @Test func endOfChapterNeedsTheChapterEndAhead() throws {
        let harness = try Harness()
        let model = harness.model()
        // At the end of the book the last chapter is still current, so the sheet offers End of Chapter and says it
        // can't start (D16); the menu can't say so, and disables it.
        harness.load(at: 400)
        #expect(SleepTimerPanelModel(timer: harness.timer, player: harness.player).offersEndOfChapter)
        #expect(!model.isEnabled(.endOfChapter))
        model.perform(.endOfChapter)
        #expect(harness.timer.mode == nil)

        // A second before it, the timer stops at the end of the media.
        harness.load(at: 399)
        #expect(model.isEnabled(.endOfChapter))
        model.perform(.endOfChapter)
        #expect(harness.timer.mode == .endOfChapter)
    }

    @Test func cancelWorksAfterItemCloses() throws {
        let harness = try Harness()
        let model = harness.model()
        harness.load(playing: true)
        model.perform(.minutes(15))
        harness.playback.phase = .idle
        #expect(!model.isEnabled(.minutes(15)))
        #expect(!model.isEnabled(.endOfChapter), "The timeline outlives the item here, as nothing cleared it")
        #expect(model.isEnabled(.cancel))
        model.perform(.cancel)
        #expect(harness.timer.mode == nil)
    }

    @Test func cancelLeavesAutomaticTimerToSheet() throws {
        let window = try AutoSleepPolicy(
            start: #require(.init(hour: 0, minute: 0)), end: #require(.init(hour: 23, minute: 59)),
            mode: .duration(60))
        let harness = try Harness(options: SleepTimerOptions(fadesOut: false, autoSleep: window))
        let model = harness.model()
        harness.load(playing: true)
        // 2023-11-14 12:00 UTC, inside the window.
        _ = harness.timer.playbackWillStart(at: Date(timeIntervalSince1970: 1_699_963_200))
        #expect(harness.timer.isAutomatic)
        #expect(!model.isEnabled(.cancel), "The sheet confirms disabling the automatic timer (D18)")
        model.perform(.cancel)
        #expect(harness.timer.isRunning)
    }
}
