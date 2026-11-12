import ABSCore
import Foundation
import Testing

@testable import ABSAppModel
@testable import ABSPlayback

/// A panel over a player and a sleep timer that share one fake playback, with settings in a fresh
/// suite. The timer's clock only moves when a test advances it, and its own ticks are 10 seconds
/// apart, so tests tick it themselves.
@MainActor
private final class Harness {
    let defaults: UserDefaults
    let suiteName = "ABSAppModelTests.SleepTimerPanel.\(UUID().uuidString)"
    let playback = FakePlaybackControl()
    let clock = ManualClock()
    let timer: SleepTimer
    let panel: SleepTimerPanelModel

    init(options: SleepTimerOptions = SleepTimerOptions(fadesOut: false)) throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        timer = SleepTimer(
            control: playback, options: options, clock: clock, calendar: .utc, tickInterval: .seconds(10))
        panel = SleepTimerPanelModel(
            timer: timer, player: PlayerViewModel(playback: playback, settings: AppSettings(defaults: defaults)))
    }

    isolated deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Loads the fake book (chapters 0–100, 100–250, 250–400) at `time`, playing.
    func load(at time: Double = 120) {
        playback.load(FakePlaybackControl.bookSession(), at: time, playing: true)
    }

    /// Plays for `seconds` and ticks.
    func play(_ seconds: Int) {
        clock.advance(by: .seconds(seconds))
        timer.tick()
    }
}

extension Calendar {
    fileprivate static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()
}

@MainActor
@Suite struct SleepTimerPanelModelTests {
    @Test func startPresetSetsDurationMode() throws {
        let harness = try Harness()
        harness.load()
        #expect(harness.panel.state == .idle)
        #expect(harness.panel.remaining == nil)

        #expect(harness.panel.start(minutes: 15))
        #expect(harness.timer.mode == .duration(900))
        #expect(harness.panel.state == .running(isAutomatic: false, isEndOfChapter: false))
        #expect(harness.panel.remaining == 900)
        #expect(harness.panel.needsCancelConfirmation == false)

        harness.panel.cancel()
        #expect(harness.panel.state == .idle)
    }

    @Test func presetsRunFromFiveMinutesToTwoHours() {
        #expect(SleepTimerPanelModel.presetMinutes == [5, 10, 15, 30, 45, 60, 90, 120])
        #expect(SleepTimerPanelModel.customMinutesRange == 1...1440)
    }

    @Test func customMinutesClampedToRange() throws {
        let harness = try Harness()
        harness.load()
        #expect(harness.panel.start(minutes: 0))
        #expect(harness.timer.mode == .duration(60))
        #expect(harness.panel.start(minutes: 5_000))
        #expect(harness.timer.mode == .duration(1_440 * 60))
        #expect(harness.panel.start(minutes: 37))
        #expect(harness.timer.mode == .duration(37 * 60))
    }

    @Test func endOfChapterOfferedOnlyWithTimeline() throws {
        let harness = try Harness()
        #expect(harness.panel.offersEndOfChapter == false, "Nothing loaded")

        // The coordinator's `.starting` phase: a session but no timeline yet.
        harness.playback.start(FakePlaybackControl.bookSession(), at: 120)
        #expect(harness.panel.offersEndOfChapter == false)

        harness.load(at: 120)
        #expect(harness.panel.offersEndOfChapter)
        #expect(harness.panel.startEndOfChapter())
        #expect(harness.panel.state == .running(isAutomatic: false, isEndOfChapter: true))
        #expect(harness.panel.remaining == 130, "To the end of the chapter at 250")
    }

    @Test func endOfChapterFailureReturnsFalse() throws {
        let harness = try Harness()
        #expect(harness.panel.startEndOfChapter() == false, "Nothing loaded")
        #expect(harness.panel.state == .idle)

        // At the end of the media the last chapter is still current, so End of Chapter is offered,
        // but there's no chapter end ahead: the sheet says so (D16).
        harness.load(at: 400)
        #expect(harness.panel.offersEndOfChapter)
        #expect(harness.panel.startEndOfChapter() == false)
        #expect(harness.panel.state == .idle)
    }

    @Test func addAndSubtractFiveMinutes() throws {
        let harness = try Harness()
        harness.load()
        harness.panel.start(minutes: 15)
        harness.panel.add()
        #expect(harness.panel.remaining == 1_200)
        harness.panel.subtract()
        harness.panel.subtract()
        #expect(harness.panel.remaining == 600)
        #expect(harness.timer.mode == .duration(600))
    }

    @Test func subtractKeepsMinimum() throws {
        let harness = try Harness()
        harness.load()
        harness.panel.start(minutes: 3)
        harness.panel.subtract()
        #expect(harness.panel.remaining == 1)
        harness.panel.subtract()
        #expect(harness.panel.remaining == 1)
        #expect(harness.panel.state == .running(isAutomatic: false, isEndOfChapter: false))
    }

    @Test func adjustmentsWithoutTimerDoNothing() throws {
        let harness = try Harness()
        harness.load()
        harness.panel.add()
        harness.panel.subtract()
        #expect(harness.panel.state == .idle)
        #expect(harness.panel.restart() == false)
    }

    @Test func automaticCancelNeedsConfirmation() throws {
        let window = try AutoSleepPolicy(
            start: #require(.init(hour: 0, minute: 0)), end: #require(.init(hour: 23, minute: 59)),
            mode: .duration(900))
        let harness = try Harness(options: SleepTimerOptions(fadesOut: false, autoSleep: window))
        harness.load()
        // 2023-11-14 12:00 UTC.
        let noon = Date(timeIntervalSince1970: 1_699_963_200)
        _ = harness.timer.playbackWillStart(at: noon)
        #expect(harness.panel.state == .running(isAutomatic: true, isEndOfChapter: false))
        #expect(harness.panel.needsCancelConfirmation)

        harness.panel.cancel()
        #expect(harness.panel.state == .idle)
        #expect(harness.panel.needsCancelConfirmation == false)
        // Cancelled, the automatic timer stays off for the rest of its window.
        _ = harness.timer.playbackWillStart(at: noon.addingTimeInterval(60))
        #expect(harness.panel.state == .idle)
    }

    @Test func restartableStateDuringGrace() async throws {
        let harness = try Harness()
        harness.load()
        harness.panel.start(minutes: 1)
        harness.play(6)
        harness.panel.subtract()
        #expect(harness.panel.remaining == 1)
        harness.play(2)
        #expect(harness.playback.isPlaying == false, "The timer paused playback")
        #expect(harness.panel.state == .idle, "Cut short by subtracting, it doesn't restart (Android)")

        harness.playback.play()
        harness.panel.start(minutes: 1)
        harness.play(5)
        harness.play(5)
        harness.play(20)
        harness.play(20)
        harness.play(20)
        #expect(harness.playback.isPlaying == false)
        #expect(harness.panel.state == .restartable)
        #expect(harness.panel.remaining == nil)

        #expect(harness.panel.restart())
        #expect(harness.panel.state == .running(isAutomatic: false, isEndOfChapter: false))
        #expect(harness.panel.remaining == 60)
        #expect(await eventually { harness.playback.isPlaying }, "The restart resumes playback")
    }
}
