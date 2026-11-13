import ABSCore
import Foundation
import Testing

@testable import ABSAppModel
@testable import ABSPlayback

/// A queue store that keeps nothing.
@MainActor
private final class NoQueueStore: PlaybackQueueStoring {
    func load(serverConnectionID: UUID) -> [QueueItem] { [] }
    func save(_ items: [QueueItem], serverConnectionID: UUID) {}
    func removeQueue(serverConnectionID: UUID) {}
}

/// A model over a fake playback, a sleep timer on it and an empty queue, with settings in a fresh suite.
@MainActor
private final class Harness {
    let defaults: UserDefaults
    let suiteName = "ABSAppModelTests.CarPlayNowPlaying.\(UUID().uuidString)"
    let playback = FakePlaybackControl()
    let timer: SleepTimer
    let queue = PlaybackQueue(serverConnectionID: FakePlaybackControl.serverID, store: NoQueueStore())
    let model: CarPlayNowPlayingModel
    var plays: [(itemID: String, episodeID: String?)] = []

    init(chapterLimit: Int = 12) throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        let timer = SleepTimer(control: playback, options: SleepTimerOptions(fadesOut: false))
        self.timer = timer
        let queue = queue
        let player = PlayerViewModel(playback: playback, settings: AppSettings(defaults: defaults))
        var playItem: PlayItemAction?
        model = CarPlayNowPlayingModel(
            player: player, sleepTimer: { timer }, queue: { queue }, playItem: { playItem },
            chapterLimit: chapterLimit)
        playItem = PlayItemAction { [weak self] itemID, episodeID, _ in self?.plays.append((itemID, episodeID)) }
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Loads the fake book (chapters 0–100, 100–250, 250–400) at `time`.
    func load(at time: Double = 120) {
        playback.load(FakePlaybackControl.bookSession(), at: time, playing: true)
    }
}

private func chapterRows(_ count: Int) -> [PlayerChapterRow] {
    (0..<count).map {
        PlayerChapterRow(id: $0, chapter: Chapter(id: $0, start: Double($0) * 60, end: Double($0 + 1) * 60, title: ""))
    }
}

@MainActor
@Suite struct CarPlayNowPlayingControlsTests {
    // MARK: Rate

    @Test func theRateCyclesThroughTheSystemsRatesAndWraps() {
        #expect(CarPlayNowPlayingControls.rates == [0.5, 0.75, 1.0, 1.25, 1.5, 2])
        #expect(CarPlayNowPlayingControls.nextRate(after: 1) == 1.25)
        #expect(CarPlayNowPlayingControls.nextRate(after: 1.5) == 2)
        #expect(CarPlayNowPlayingControls.nextRate(after: 2) == 0.5)
    }

    @Test func aRateOffTheListGoesToTheNextLargerOne() {
        #expect(CarPlayNowPlayingControls.nextRate(after: 1.2) == 1.25)
        #expect(CarPlayNowPlayingControls.nextRate(after: 3) == 0.5)
        #expect(CarPlayNowPlayingControls.nextRate(after: 1.2500000001) == 1.5, "Within tolerance of 1.25")
    }

    @Test func theButtonsShowTheRateAndATapSetsTheNext() throws {
        let harness = try Harness()
        harness.load()
        harness.playback.rate = 1.5
        #expect(harness.model.buttons.rate == 1.5)

        harness.model.cycleRate()
        #expect(harness.playback.calls.last == .setRate(2))
        #expect(harness.model.buttons.rate == 2)
    }

    // MARK: Sleep timer

    @Test func theSleepTimerCyclesThroughPresetsThenEndOfChapterThenOff() {
        func next(_ mode: SleepTimerMode?, chapters: Bool = true) -> CarPlaySleepTimerAction {
            CarPlayNowPlayingControls.sleepTimerAction(after: mode, offersEndOfChapter: chapters)
        }
        #expect(next(nil) == .start(.duration(15 * 60)))
        #expect(next(.duration(15 * 60)) == .start(.duration(30 * 60)))
        #expect(next(.duration(30 * 60)) == .start(.duration(45 * 60)))
        #expect(next(.duration(45 * 60)) == .start(.duration(60 * 60)))
        #expect(next(.duration(60 * 60)) == .start(.endOfChapter))
        #expect(next(.endOfChapter) == .cancel)
        #expect(next(.duration(60 * 60), chapters: false) == .cancel, "No end of chapter to stop at")
        #expect(next(.duration(20 * 60)) == .start(.duration(30 * 60)), "A timer with time added")
    }

    @Test func theSleepTimerIsSelectedWhileATimerRuns() {
        #expect(CarPlayNowPlayingControls.isSleepTimerActive(nil) == false)
        #expect(CarPlayNowPlayingControls.isSleepTimerActive(.duration(60)))
        #expect(CarPlayNowPlayingControls.isSleepTimerActive(.endOfChapter))
    }

    @Test func tappingTheSleepTimerStartsEachPresetAndSelectsTheButton() throws {
        let harness = try Harness()
        harness.load(at: 120)
        #expect(harness.model.buttons.isSleepTimerActive == false)

        harness.model.cycleSleepTimer()
        #expect(harness.timer.mode == .duration(15 * 60))
        #expect(harness.model.buttons.isSleepTimerActive)
        for minutes in [30, 45, 60] {
            harness.model.cycleSleepTimer()
            #expect(harness.timer.mode == .duration(TimeInterval(minutes) * 60))
        }
        harness.model.cycleSleepTimer()
        #expect(harness.timer.mode == .endOfChapter)
        harness.model.cycleSleepTimer()
        #expect(harness.timer.mode == nil)
        #expect(harness.model.buttons.isSleepTimerActive == false)
    }

    @Test func anEndOfChapterThatCantStartTurnsTheTimerOff() throws {
        let harness = try Harness()
        harness.load(at: 400)
        for _ in 0..<4 { harness.model.cycleSleepTimer() }
        #expect(harness.timer.mode == .duration(60 * 60))

        harness.model.cycleSleepTimer()
        #expect(harness.timer.mode == nil, "No chapter end ahead at the end of the media")
    }

    // MARK: Chapters and Up Next

    @Test func theChapterListMarksTheCurrentChapterAndSeeksToItsStart() async throws {
        let harness = try Harness()
        harness.load(at: 120)

        let rows = harness.model.chapters
        #expect(rows.map(\.id) == [0, 1, 2])
        #expect(rows.map(\.chapter.title) == ["Opening", "Middle", "Ending"])
        #expect(rows.map(\.isCurrent) == [false, true, false])
        #expect(rows.map(\.seekTarget) == [0, 100, 250])

        let ending = try #require(rows.last)
        await harness.model.select(ending)
        #expect(harness.playback.calls.last == .seek(250))
        #expect(harness.model.chapters.map(\.isCurrent) == [false, false, true])
    }

    @Test func aLongChapterListShowsAWindowAroundTheCurrentChapter() {
        let chapters = chapterRows(30)
        func ids(_ current: Int?) -> [Int] {
            CarPlayNowPlayingControls.chapterRows(chapters, currentIndex: current, limit: 5).map(\.id)
        }
        #expect(ids(nil) == [0, 1, 2, 3, 4])
        #expect(ids(0) == [0, 1, 2, 3, 4])
        #expect(ids(10) == [9, 10, 11, 12, 13])
        #expect(ids(29) == [25, 26, 27, 28, 29])
        let rows = CarPlayNowPlayingControls.chapterRows(chapters, currentIndex: 10, limit: 5)
        #expect(rows.filter(\.isCurrent).map(\.id) == [10])
        #expect(rows.first?.seekTarget == 540)
    }

    @Test func withoutChaptersTheListIsEmptyAndTheButtonDisabled() throws {
        let harness = try Harness()
        harness.playback.load(FakePlaybackControl.bookSession(chapters: []))
        #expect(harness.model.chapters.isEmpty)
        #expect(harness.model.buttons.hasChapters == false)
        #expect(harness.model.buttons.upNext == nil)
    }

    @Test func upNextOpensTheQueueWhenItHasItemsElseTheChapters() throws {
        #expect(CarPlayNowPlayingControls.upNext(queueCount: 2, hasChapters: true) == .queue)
        #expect(CarPlayNowPlayingControls.upNext(queueCount: 0, hasChapters: true) == .chapters)
        #expect(CarPlayNowPlayingControls.upNext(queueCount: 0, hasChapters: false) == nil)

        let harness = try Harness()
        harness.load()
        #expect(harness.model.buttons.upNext == .chapters)
        harness.queue.addToEnd(QueueItem(libraryItemID: "next", title: "Next"))
        #expect(harness.model.buttons.upNext == .queue)
        #expect(harness.model.queueRows.map(\.title) == ["Next"])
    }

    @Test func aQueueRowPlaysThroughThePlayAction() async throws {
        let harness = try Harness()
        harness.queue.addToEnd(QueueItem(libraryItemID: "podcast", episodeID: "ep", title: "Episode"))
        let row = try #require(harness.model.queueRows.first)
        #expect(await harness.model.play(row))
        #expect(harness.plays.map(\.itemID) == ["podcast"])
        #expect(harness.plays.map(\.episodeID) == ["ep"])
    }
}
