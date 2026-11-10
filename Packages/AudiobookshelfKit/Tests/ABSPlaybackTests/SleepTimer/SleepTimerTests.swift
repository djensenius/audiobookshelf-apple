import ABSCore
import Foundation
import Testing

@testable import ABSPlayback

/// A timer on a manual clock that ticks every second, with fake playback, feedback and shake detection.
@MainActor
private final class Harness {
    let clock = ManualClock()
    let control: FakePlaybackControl
    let feedback = FakeFeedback()
    let shake = FakeShakeDetector()
    let timer: SleepTimer

    init(timeline: PlaybackTimeline? = nil, at time: Double = 0, options: SleepTimerOptions = SleepTimerOptions()) {
        control = FakePlaybackControl(timeline: timeline, at: time)
        timer = SleepTimer(
            control: control, feedback: feedback, shakeDetector: shake, options: options, clock: clock,
            calendar: .gregorianUTC, tickInterval: .seconds(1))
    }

    func advance(_ seconds: Int) async {
        await advanceTicking(clock, timer, seconds: seconds)
    }

    /// Plays from `start` to `end` one second per tick.
    func play(from start: Double, to end: Double) async {
        var time = start
        while time < end {
            time += 1
            control.currentTime = time
            await advance(1)
        }
    }

    /// Expires a running duration timer and checks it can restart.
    func expire() async {
        guard case .duration(let length) = timer.mode, let remaining = timer.remaining else {
            Issue.record("No duration timer running")
            return
        }
        await advance(Int(remaining.rounded(.up)))
        #expect(timer.isRunning == false)
        #expect(control.pauseCount > 0, "Timer of \(length) s should pause")
    }

    func endGrace() async {
        clock.advance(by: .seconds(SleepTimer.gracePeriod))
        await until { !timer.canRestart }
    }
}

private let chapters = TimelineFixture.crossingChapters.timeline

private func autoOptions(mode: SleepTimerMode = .duration(10), rewind: TimeInterval? = 300) throws -> SleepTimerOptions
{
    let start = try #require(AutoSleepPolicy.TimeOfDay("22:00"))
    let end = try #require(AutoSleepPolicy.TimeOfDay("06:00"))
    return SleepTimerOptions(autoSleep: AutoSleepPolicy(start: start, end: end, mode: mode, rewindOnExpiry: rewind))
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SleepTimerTests {
    // MARK: - Duration

    @Test func pausesOnExpiryThenRestoresTheVolume() async {
        let harness = Harness()
        #expect(harness.timer.start(.duration(5)))
        #expect(harness.timer.mode == .duration(5))
        await harness.advance(4)
        #expect(harness.control.pauseCount == 0)
        #expect(harness.timer.remaining == 1)

        await harness.advance(1)
        #expect(harness.control.pauseCount == 1)
        #expect(harness.control.volumeAtPause == Float(1.0 / 60))
        #expect(harness.control.volume == 1)
        #expect(harness.timer.isRunning == false)
        #expect(harness.timer.remaining == nil)
        #expect(harness.timer.isTicking == false)
    }

    @Test func countsDownOnlyWhilePlaying() async {
        let harness = Harness()
        harness.timer.start(.duration(10))
        await harness.advance(3)
        harness.control.isPlaying = false
        await harness.advance(5)
        #expect(harness.timer.remaining == 7)

        harness.control.isPlaying = true
        await harness.advance(6)
        #expect(harness.timer.isRunning)
        await harness.advance(1)
        #expect(harness.timer.isRunning == false)
        #expect(harness.control.pauseCount == 1)
    }

    @Test func rejectsLengthsThatArentPositive() {
        let harness = Harness()
        #expect(harness.timer.start(.duration(0)) == false)
        #expect(harness.timer.start(.duration(-5)) == false)
        #expect(harness.timer.start(.duration(.infinity)) == false)
        #expect(harness.timer.isRunning == false)
    }

    @Test func settingsLengthZeroMeansEndOfChapter() {
        #expect(SleepTimerMode(settingsLength: 0) == .endOfChapter)
        #expect(SleepTimerMode(settingsLength: 900_000) == .duration(900))
    }

    // MARK: - Fade and chime

    @Test func fadesLinearlyOverTheLastMinute() async {
        let harness = Harness()
        harness.timer.start(.duration(70))
        await harness.advance(10)
        #expect(harness.control.volumes.isEmpty)

        await harness.advance(60)
        let ramp = (1...59).reversed().map { Float(Double($0) / 60) }
        #expect(harness.control.volumes == ramp + [1])
        #expect(harness.control.volumeAtPause == Float(1.0 / 60))
    }

    @Test func doesNotFadeWhenDisabled() async {
        let harness = Harness(options: SleepTimerOptions(fadesOut: false))
        harness.timer.start(.duration(30))
        await harness.advance(30)
        #expect(harness.control.pauseCount == 1)
        #expect(harness.control.volumes.isEmpty)
    }

    @Test func chimesOnceThirtySecondsBeforeTheEnd() async {
        let harness = Harness(options: SleepTimerOptions(playsAlmostDoneChime: true))
        harness.timer.start(.duration(40))
        await harness.advance(9)
        #expect(harness.feedback.chimes == 0)
        await harness.advance(1)
        #expect(harness.feedback.chimes == 1)

        harness.control.isPlaying = false
        await harness.advance(2)
        harness.control.isPlaying = true
        await harness.advance(30)
        #expect(harness.control.pauseCount == 1)
        #expect(harness.feedback.chimes == 1)
    }

    @Test func chimesOncePerRunEvenAfterAddingTime() async {
        let harness = Harness(options: SleepTimerOptions(playsAlmostDoneChime: true))
        harness.timer.start(.duration(20))
        await harness.advance(5)
        #expect(harness.feedback.chimes == 0, "A run that starts inside the lead time doesn't chime at once")

        harness.timer.add(30)
        await harness.advance(15)
        #expect(harness.feedback.chimes == 1)

        harness.timer.add(10)
        await harness.advance(40)
        #expect(harness.control.pauseCount == 1)
        #expect(harness.feedback.chimes == 1)
    }

    @Test func neverChimesForARunStartedInsideTheLeadTime() async {
        let harness = Harness(options: SleepTimerOptions(playsAlmostDoneChime: true))
        harness.timer.start(.duration(20))
        await harness.advance(20)
        #expect(harness.control.pauseCount == 1)
        #expect(harness.feedback.chimes == 0)
    }

    @Test func doesNotChimeWhenDisabled() async {
        let harness = Harness()
        harness.timer.start(.duration(40))
        await harness.advance(40)
        #expect(harness.control.pauseCount == 1)
        #expect(harness.feedback.chimes == 0)
    }

    // MARK: - End of chapter

    @Test func endOfChapterPausesAtTheChapterEnd() async {
        let harness = Harness(timeline: chapters, at: 100)
        #expect(harness.timer.start(.endOfChapter))
        #expect(harness.timer.mode == .endOfChapter)
        #expect(harness.timer.remaining == 350)

        harness.control.currentTime = 440
        await harness.play(from: 440, to: 449)
        #expect(harness.timer.remaining == 1)
        #expect(harness.control.pauseCount == 0)
        await harness.play(from: 449, to: 450)
        #expect(harness.control.pauseCount == 1)
        #expect(harness.timer.isRunning == false)
    }

    @Test func endOfChapterWithLessThanTenSecondsLeftUsesTheNextChapter() {
        let harness = Harness(timeline: chapters, at: 445)
        harness.timer.start(.endOfChapter)
        #expect(harness.timer.remaining == 555)

        harness.control.currentTime = 440
        harness.timer.start(.endOfChapter)
        #expect(harness.timer.remaining == 10)
    }

    @Test func endOfChapterFollowsSeeksAndChapterChanges() async {
        let harness = Harness(timeline: chapters, at: 100)
        harness.timer.start(.endOfChapter)

        harness.control.currentTime = 1200
        harness.timer.didSeek(to: 1200)
        #expect(harness.timer.remaining == 600)

        harness.control.currentTime = 445
        harness.timer.didSeek(to: 445)
        #expect(harness.timer.remaining == 5, "A seek keeps the chapter even with less than 10 s left")

        await harness.play(from: 445, to: 450)
        #expect(harness.control.pauseCount == 1)
    }

    @Test func pausedEndOfChapterWaitsForASeekToLand() async {
        let harness = Harness(timeline: chapters, at: 100)
        harness.timer.start(.endOfChapter)
        harness.control.isPlaying = false
        harness.control.currentTime = 500
        await harness.advance(1)
        #expect(harness.timer.isRunning)

        harness.timer.didSeek(to: 500)
        #expect(harness.timer.remaining == 500)
    }

    @Test func endOfChapterExpiresAtTheEndOfTheMediaWhilePaused() async {
        let harness = Harness(timeline: chapters, at: 1700)
        harness.timer.start(.endOfChapter)
        harness.control.isPlaying = false
        harness.control.currentTime = 1800
        await harness.advance(1)
        #expect(harness.timer.isRunning == false)
        #expect(harness.control.pauseCount == 1)
    }

    @Test func endOfChapterCountsWallClockSecondsAtTheRate() {
        let harness = Harness(timeline: chapters, at: 100)
        harness.control.rate = 2
        harness.timer.start(.endOfChapter)
        #expect(harness.timer.remaining == 175)
    }

    @Test func endOfChapterWithoutChaptersUsesTheTrackEnd() {
        let harness = Harness(timeline: TimelineFixture.podcast.timeline, at: 100)
        harness.timer.start(.endOfChapter)
        #expect(harness.timer.remaining == 2600)
    }

    @Test func endOfChapterNeedsATimeline() {
        let harness = Harness()
        #expect(harness.timer.start(.endOfChapter) == false)
        #expect(harness.timer.isRunning == false)
    }

    // MARK: - Adjusting

    @Test func addsAndSubtractsTime() async {
        let harness = Harness()
        harness.timer.add(60)
        #expect(harness.timer.isRunning == false)

        harness.timer.start(.duration(600))
        harness.timer.add(300)
        #expect(harness.timer.mode == .duration(900))
        harness.timer.subtract(120)
        #expect(harness.timer.mode == .duration(780))
        await harness.advance(10)
        #expect(harness.timer.remaining == 770)
    }

    @Test func subtractingPastTheEndLeavesOneSecondAndNoRestart() async {
        let harness = Harness()
        harness.timer.start(.duration(600))
        await harness.advance(10)
        harness.timer.subtract(1000)
        #expect(harness.timer.remaining == 1)
        #expect(harness.timer.mode == .duration(11))

        await harness.advance(1)
        #expect(harness.control.pauseCount == 1)
        #expect(harness.timer.canRestart == false)
        #expect(harness.shake.sensitivity == nil)
        #expect(harness.timer.playbackWillStart() == 0)
        #expect(harness.timer.isRunning == false)
    }

    @Test func addingAfterCuttingShortAllowsARestart() async {
        let harness = Harness()
        harness.timer.start(.duration(600))
        harness.timer.subtract(1000)
        harness.timer.add(4)
        await harness.advance(5)
        #expect(harness.control.pauseCount == 1)
        #expect(harness.timer.canRestart)
    }

    @Test func addsAndSubtractsChapterTimeAtTheRate() {
        let harness = Harness(timeline: chapters, at: 100)
        harness.control.rate = 2
        harness.timer.start(.endOfChapter)
        harness.timer.add(60)
        #expect(harness.timer.remaining == 235)
        harness.timer.subtract(200)
        #expect(harness.timer.remaining == 35)
        harness.timer.add(10_000)
        #expect(harness.timer.remaining == 850, "Capped at the end of the media")
    }

    @Test func adjustingRefreshesTheFade() {
        let harness = Harness()
        harness.timer.start(.duration(30))
        #expect(harness.control.volume == 0.5)
        harness.timer.add(60)
        #expect(harness.control.volume == 1)
        harness.timer.subtract(75)
        #expect(harness.control.volume == 0.25)
    }

    @Test func cancelStopsTheTimerAndRestoresTheVolume() async {
        let harness = Harness()
        harness.timer.start(.duration(30))
        #expect(harness.shake.sensitivity == .medium)
        harness.timer.cancel()
        #expect(harness.control.volume == 1)
        #expect(harness.timer.isRunning == false)
        #expect(harness.timer.remaining == nil)
        #expect(harness.timer.isTicking == false)
        #expect(harness.shake.sensitivity == nil)
        await harness.advance(60)
        #expect(harness.control.pauseCount == 0)
    }

    // MARK: - Reset

    @Test func shakeResetsToTheAdjustedLengthAfterThreeSeconds() async {
        let harness = Harness()
        harness.timer.start(.duration(600))
        harness.timer.add(60)
        await harness.advance(3)
        harness.shake.shake()
        #expect(harness.timer.remaining == 657)
        #expect(harness.feedback.resets == 0)

        await harness.advance(1)
        harness.shake.shake()
        #expect(harness.timer.remaining == 660)
        #expect(harness.feedback.resets == 1)
    }

    @Test func resetNeedsPlayback() async {
        let harness = Harness()
        harness.timer.start(.duration(600))
        await harness.advance(5)
        harness.control.isPlaying = false
        #expect(harness.timer.reset() == false)
        #expect(harness.timer.remaining == 595)
    }

    @Test func resetWithoutFeedbackWhenDisabled() async {
        let harness = Harness(options: SleepTimerOptions(playsResetFeedback: false))
        harness.timer.start(.duration(600))
        await harness.advance(5)
        #expect(harness.timer.reset())
        #expect(harness.feedback.resets == 0)
    }

    @Test func resetRecomputesTheChapterEnd() {
        let harness = Harness(timeline: chapters, at: 100)
        harness.timer.start(.endOfChapter)
        harness.control.currentTime = 445
        #expect(harness.timer.reset())
        #expect(harness.timer.remaining == 555)
    }

    @Test func shakeDuringTheGracePeriodRestartsAndPlays() async {
        let harness = Harness()
        harness.timer.start(.duration(10))
        await harness.expire()
        #expect(harness.timer.canRestart)
        #expect(harness.shake.sensitivity == .medium)

        harness.clock.advance(by: .seconds(60))
        harness.shake.shake()
        #expect(harness.timer.mode == .duration(10))
        #expect(harness.timer.canRestart == false)
        #expect(harness.control.plays == [0])
        #expect(harness.control.isPlaying)
        #expect(harness.feedback.resets == 1)
    }

    @Test func playingDuringTheGracePeriodRestarts() async {
        let harness = Harness()
        harness.timer.start(.duration(10))
        await harness.expire()
        #expect(harness.timer.playbackWillStart() == 0)
        #expect(harness.timer.mode == .duration(10))
        #expect(harness.feedback.resets == 1)
    }

    @Test func noRestartAfterTheGracePeriod() async {
        let harness = Harness()
        harness.timer.start(.duration(10))
        await harness.expire()
        await harness.endGrace()
        #expect(harness.shake.sensitivity == nil)
        #expect(harness.timer.reset() == false)
        #expect(harness.timer.playbackWillStart() == 0)
        #expect(harness.timer.isRunning == false)
        #expect(harness.control.plays.isEmpty)
    }

    @Test func runningTimerIsNotResetByPlay() async {
        let harness = Harness()
        harness.timer.start(.duration(600))
        await harness.advance(5)
        #expect(harness.timer.playbackWillStart() == 0)
        #expect(harness.timer.remaining == 595)
    }

    // MARK: - Shake detection

    @Test func shakeDetectionFollowsTheTimerAndSettings() {
        let harness = Harness(options: SleepTimerOptions(shakeSensitivity: nil))
        harness.timer.start(.duration(600))
        #expect(harness.shake.sensitivity == nil)

        harness.timer.options.shakeSensitivity = .high
        #expect(harness.shake.sensitivity == .high)
        harness.timer.options.shakeSensitivity = .veryLow
        #expect(harness.shake.sensitivity == .veryLow)
        #expect(harness.shake.starts == 2)

        harness.timer.options.fadesOut = false
        #expect(harness.shake.starts == 2)
        harness.timer.options.shakeSensitivity = nil
        #expect(harness.shake.sensitivity == nil)
    }

    // MARK: - Automatic timer

    @Test func automaticTimerStartsInsideTheWindowOnly() throws {
        let harness = Harness(options: try autoOptions())
        #expect(harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 12, 0)) == 0)
        #expect(harness.timer.isRunning == false)

        #expect(harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 23, 0)) == 0)
        #expect(harness.timer.mode == .duration(10))
        #expect(harness.timer.isAutomatic)
    }

    @Test func automaticTimerRewindsWhenPlayingAgain() async throws {
        let harness = Harness(at: 1000, options: try autoOptions())
        _ = harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 23, 0))
        await harness.expire()
        await harness.endGrace()

        #expect(harness.timer.playbackWillStart(at: try makeDate(2026, 1, 16, 7, 30)) == 300)
        #expect(harness.timer.isRunning == false, "Outside the window")
        #expect(harness.timer.playbackWillStart(at: try makeDate(2026, 1, 16, 7, 31)) == 0, "Consumed")
    }

    @Test func automaticTimerRewindsBeforeTheNextAutomaticTimer() async throws {
        let harness = Harness(at: 1000, options: try autoOptions())
        _ = harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 23, 0))
        await harness.expire()
        await harness.endGrace()

        #expect(harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 23, 20)) == 300)
        #expect(harness.timer.isAutomatic)
    }

    @Test func shakeAfterAnAutomaticTimerRewindsAndPlays() async throws {
        let harness = Harness(at: 1000, options: try autoOptions())
        _ = harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 23, 0))
        await harness.expire()

        harness.shake.shake()
        #expect(harness.control.plays == [300])
        #expect(harness.control.currentTime == 700)
        #expect(harness.timer.isAutomatic)
        #expect(harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 23, 11)) == 0)
    }

    @Test func automaticChapterTimerRestartsFromTheRewoundPosition() async throws {
        let harness = Harness(timeline: chapters, at: 1000, options: try autoOptions(mode: .endOfChapter))
        harness.control.currentTime = 400
        _ = harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 23, 0))
        #expect(harness.timer.remaining == 50)
        await harness.play(from: 400, to: 450)
        #expect(harness.timer.canRestart)

        #expect(harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 23, 2)) == 300)
        #expect(harness.timer.remaining == 300, "Ends at 450 again, counted from 150")
    }

    @Test func manualTimerClearsThePendingRewind() async throws {
        let harness = Harness(options: try autoOptions())
        _ = harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 23, 0))
        await harness.expire()
        harness.timer.start(.duration(60))
        #expect(harness.timer.isAutomatic == false)
        harness.timer.cancel()
        #expect(harness.timer.playbackWillStart(at: try makeDate(2026, 1, 16, 7, 0)) == 0)
    }

    @Test func manualTimerDoesNotRewind() async throws {
        let harness = Harness(options: try autoOptions())
        harness.timer.start(.duration(5))
        await harness.expire()
        await harness.endGrace()
        #expect(harness.timer.playbackWillStart(at: try makeDate(2026, 1, 16, 7, 0)) == 0)
    }

    @Test func cancellingAnAutomaticTimerSuppressesItUntilTheWindowEnds() throws {
        let harness = Harness(options: try autoOptions())
        _ = harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 23, 0))
        harness.timer.cancel(at: try makeDate(2026, 1, 15, 23, 5))
        #expect(harness.timer.isRunning == false)

        _ = harness.timer.playbackWillStart(at: try makeDate(2026, 1, 16, 5, 59))
        #expect(harness.timer.isRunning == false)
        _ = harness.timer.playbackWillStart(at: try makeDate(2026, 1, 16, 22, 0))
        #expect(harness.timer.isAutomatic)
    }

    // MARK: - Platform

    @Test func chimeIsAQuietSecondAndAHalf() throws {
        let buffer = try #require(SystemSleepTimerFeedback.makeChime())
        #expect(buffer.frameLength == 66_150)
        let samples = try #require(buffer.floatChannelData?[0])
        let peak = (0..<Int(buffer.frameLength)).map { abs(samples[$0]) }.max() ?? 0
        #expect(peak > 0.5)
        #expect(peak <= 1)
    }
}
