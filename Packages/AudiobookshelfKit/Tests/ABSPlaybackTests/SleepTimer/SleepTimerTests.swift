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

/// Tracks over `ranges` (with gaps between them), and chapters ending at `chapterEnd` and at the end.
private func gappedTimeline(_ ranges: [ClosedRange<Double>], chapterEnd: Double) -> PlaybackTimeline {
    let tracks = ranges.enumerated().map { index, range in
        AudioTrack(index: index + 1, startOffset: range.lowerBound, duration: range.upperBound - range.lowerBound)
    }
    let end = ranges.last?.upperBound ?? chapterEnd
    return PlaybackTimeline(
        tracks: tracks,
        chapters: [Chapter(id: 0, start: 0, end: chapterEnd), Chapter(id: 1, start: chapterEnd, end: end)])
}

/// How a grace period ends.
enum GraceEnd: CaseIterable, Sendable { case graceTask, clockOnly, cancel, anotherItem }
/// What happens between an automatic timer's expiry and the next play.
enum Move: CaseIterable, Sendable { case none, seek, unreportedSeek, anotherItem }
/// What happens during the seek back to where an expired timer's fade began.
enum ExpirySeek: CaseIterable, Sendable { case play, manualStart, failure, userSeek }
/// What happens before a grace-period reset's rewind seek, or during it.
enum ResetRace: CaseIterable, Sendable { case cancelBefore, startBefore, itemBefore, cancelDuring, itemDuring }

private func autoOptions(mode: SleepTimerMode = .duration(10), rewind: TimeInterval? = 300) throws -> SleepTimerOptions
{
    let start = try #require(AutoSleepPolicy.TimeOfDay("22:00"))
    let end = try #require(AutoSleepPolicy.TimeOfDay("06:00"))
    return SleepTimerOptions(autoSleep: AutoSleepPolicy(start: start, end: end, mode: mode, rewindOnExpiry: rewind))
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
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

    @Test func rejectsTimersThatCantRun() {
        let harness = Harness()
        #expect(harness.timer.start(.duration(0)) == false)
        #expect(harness.timer.start(.duration(-5)) == false)
        #expect(harness.timer.start(.duration(.infinity)) == false)
        #expect(harness.timer.start(.endOfChapter) == false, "No timeline")
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

    @Test func doesNotFadeOrChimeWhenDisabled() async {
        let harness = Harness(options: SleepTimerOptions(fadesOut: false, playsAlmostDoneChime: false))
        harness.timer.start(.duration(40))
        await harness.advance(40)
        #expect(harness.control.pauseCount == 1)
        #expect(harness.control.volumes.isEmpty)
        #expect(harness.feedback.chimes == 0)
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

    @Test func chimesOnceASlowerRateLiftsAChapterAboveTheLeadTime() async {
        let harness = Harness(timeline: chapters, at: 400, options: SleepTimerOptions(playsAlmostDoneChime: true))
        harness.control.rate = 2
        harness.timer.start(.endOfChapter)
        #expect(harness.timer.remaining == 25)
        harness.control.rate = 1
        await harness.play(from: 400, to: 419)
        #expect(harness.feedback.chimes == 0)
        await harness.play(from: 419, to: 420)
        #expect(harness.feedback.chimes == 1, "30 s before the end at 1×")
    }

    /// Starting inside the lead time, cutting well into it, or cutting just below it, skips the chime.
    @Test(arguments: [(20.0, 0.0), (600, 580), (600, 570.25)])
    func neverChimesForARunStartedOrCutInsideTheLeadTime(length: Double, cut: Double) async {
        let harness = Harness(options: SleepTimerOptions(playsAlmostDoneChime: true))
        harness.timer.start(.duration(length))
        harness.timer.subtract(cut)
        await harness.advance(30)
        #expect(harness.control.pauseCount == 1)
        #expect(harness.feedback.chimes == 0, "Jumping past the chime skips it")
    }

    @Test func expirySeeksBackToWhereTheFadeBegan() async {
        let harness = Harness(at: 100)
        harness.timer.start(.duration(30))
        await harness.play(from: 100, to: 110)
        harness.timer.add(45)
        #expect(harness.control.volume == 1, "Back above the fade, which starts again at 115")

        await harness.play(from: 110, to: 175)
        #expect(harness.control.pauseCount == 1)
        await until { harness.control.currentTime == 115 }
        #expect(harness.control.seeks == [115])
        #expect(harness.timer.playbackWillStart() == 0)
        #expect(harness.timer.isRunning, "Restarted within the grace period")
    }

    /// Another item, or a seek that landed, before the expiry's seek task runs wins: no rewind to the fade.
    @Test(arguments: [false, true])
    func aChangeBeforeTheExpirySeekWins(userSeeks: Bool) async {
        let harness = Harness(at: 100)
        harness.timer.start(.duration(30))
        await harness.play(from: 100, to: 130)
        #expect(harness.control.pauseCount == 1)
        if userSeeks { harness.control.currentTime = 5000 } else { harness.timer.itemDidChange("other") }
        await Task { @MainActor in }.value  // Queued after the expiry's seek task, so that has run.
        #expect(harness.control.seeks.isEmpty)
    }

    @Test func aSeekDuringTheFadeRewindsOnlyToTheSeek() async {
        let harness = Harness(at: 100)
        harness.timer.start(.duration(30))
        await harness.play(from: 100, to: 110)
        harness.control.currentTime = 500
        harness.timer.didSeek(to: 500)
        await harness.play(from: 500, to: 520)
        #expect(harness.control.pauseCount == 1)
        await until { harness.control.currentTime == 500 }
        #expect(harness.control.seeks == [500])
    }

    @Test func endOfChapterDoesNotRewindAfterItsFade() async {
        let harness = Harness(timeline: chapters, at: 400)
        harness.timer.start(.endOfChapter)
        await harness.play(from: 400, to: 450)
        #expect(harness.control.pauseCount == 1)
        await harness.endGrace()
        #expect(harness.timer.playbackWillStart() == 0)
        #expect(harness.control.seeks.isEmpty)
    }

    // MARK: - End of chapter

    @Test func endOfChapterFollowsSeeksAndPausesAtTheChapterEnd() async {
        let harness = Harness(timeline: chapters, at: 100)
        #expect(harness.timer.start(.endOfChapter))
        #expect(harness.timer.mode == .endOfChapter)
        #expect(harness.timer.remaining == 350)

        harness.control.currentTime = 1200
        harness.timer.didSeek(to: 1200)
        #expect(harness.timer.remaining == 600)
        harness.control.currentTime = 445
        harness.timer.didSeek(to: 445)
        #expect(harness.timer.remaining == 5, "A seek keeps the chapter even with less than 10 s left")

        await harness.play(from: 445, to: 449)
        #expect(harness.timer.remaining == 1)
        #expect(harness.control.pauseCount == 0)
        await harness.play(from: 449, to: 450)
        #expect(harness.control.pauseCount == 1)
        #expect(harness.timer.isRunning == false)
    }

    /// Under 10 media seconds of the chapter left, at any rate, the next chapter (Android `getChapterEndTime`).
    @Test(arguments: [(440.0, 1.0, 10.0), (440.5, 1, 559.5), (431, 2, 9.5), (440.5, 2, 279.75)])
    func endOfChapterWithLessThanTenSecondsLeftUsesTheNextChapter(time: Double, rate: Double, remaining: Double) {
        let harness = Harness(timeline: chapters, at: time)
        harness.control.rate = rate
        harness.timer.start(.endOfChapter)
        #expect(harness.timer.remaining == remaining)
    }

    @Test(arguments: zip([1, 0.75, 1], [447.3, 440, 440]))
    func aResumeRewindBeforeTheNextChapterKeepsItsEnd(rate: Double, landing: Double) async {
        let harness = Harness(timeline: chapters, at: 440)
        harness.control.rate = rate
        harness.timer.start(.endOfChapter)
        await harness.play(from: 440, to: 449)
        harness.control.currentTime = 450.3
        await harness.advance(1)
        #expect(harness.control.pauseCount == 1)

        harness.clock.advance(by: .seconds(20))
        #expect(harness.timer.playbackWillStart() == 0)
        harness.control.isPlaying = true
        harness.control.currentTime = landing
        harness.timer.didSeek(to: landing)
        #expect(abs((harness.timer.remaining ?? 0) - (1000 - landing) / rate) < 1e-9)
        await harness.play(from: landing, to: landing + 12)
        #expect(harness.control.pauseCount == 1)
    }

    @Test func aSeekKeepsTheNextChapterOnlyUpToThirtySecondsBeforeIt() {
        let harness = Harness(timeline: chapters, at: 500)
        harness.timer.start(.endOfChapter)
        harness.control.currentTime = 420
        harness.timer.didSeek(to: 420)
        #expect(harness.timer.remaining == 580)
        harness.control.currentTime = 419
        harness.timer.didSeek(to: 419)
        #expect(harness.timer.remaining == 31)
    }

    @Test func anUnreportedJumpRetargetsInsteadOfExpiring() async {
        let harness = Harness(timeline: chapters, at: 400)
        harness.timer.start(.endOfChapter)
        harness.control.currentTime = 450
        await harness.advance(1)
        #expect(harness.control.pauseCount == 0)
        #expect(harness.timer.remaining == 550)
    }

    @Test func playingAcrossAGapBetweenTracksIsntASeek() async {
        let harness = Harness(timeline: TimelineFixture.gappedTracks.timeline, at: 90)
        harness.timer.start(.endOfChapter)
        await harness.play(from: 90, to: 99)
        #expect(harness.timer.remaining == 1)
        harness.control.currentTime = 110.5
        await harness.advance(1)
        #expect(harness.control.pauseCount == 1, "At the end of the first track")
        #expect(harness.timer.isRunning == false)
    }

    @Test func chapterTimeLeftLeavesOutGapsBetweenTracks() async {
        let timeline = gappedTimeline([5...100, 110...200], chapterEnd: 120)
        let harness = Harness(timeline: timeline, at: 70, options: SleepTimerOptions(playsAlmostDoneChime: true))
        harness.timer.start(.endOfChapter)
        #expect(harness.timer.remaining == 40, "30 s of the first track, then 10 of the second")
        await harness.play(from: 70, to: 80)
        #expect(harness.feedback.chimes == 1, "30 s before the end")
        await harness.play(from: 80, to: 100)
        #expect(harness.timer.remaining == 10)
        harness.control.currentTime = 110
        await harness.advance(1)
        #expect(harness.timer.remaining == 10)
        #expect(harness.control.volumes.suffix(2) == [Float(11.0 / 60), Float(10.0 / 60)], "No jump across the gap")
        await harness.play(from: 110, to: 120)
        #expect(harness.control.pauseCount == 1)
    }

    @Test func aSeekDuringTheChapterFadeRestoresTheVolume() {
        let harness = Harness(timeline: chapters, at: 420)
        harness.timer.start(.endOfChapter)
        #expect(harness.control.volume == 0.5)
        harness.control.currentTime = 500
        harness.timer.didSeek(to: 500)
        #expect(harness.control.volume == 1)
        #expect(harness.timer.remaining == 500)
    }

    @Test func aRateChangeRescalesTheChapterTime() async {
        let harness = Harness(timeline: chapters, at: 100)
        harness.timer.start(.endOfChapter)
        #expect(harness.timer.remaining == 350)
        harness.control.rate = 2
        await harness.advance(1)
        #expect(harness.timer.remaining == 175)
    }

    @Test func endOfChapterAcrossGapsAndWithoutChapters() {
        let harness = Harness(timeline: TimelineFixture.chapterGaps.timeline, at: 5)
        harness.timer.start(.endOfChapter)
        #expect(harness.timer.remaining == 95, "5 s to the first chapter, so its end")
        harness.control.currentTime = 120
        harness.timer.start(.endOfChapter)
        #expect(harness.timer.remaining == 30, "In a gap, the next chapter's start")
        harness.control.currentTime = 95
        harness.timer.start(.endOfChapter)
        #expect(harness.timer.remaining == 55, "5 s left, so the end of the gap after it")
        harness.control.timeline = TimelineFixture.podcast.timeline
        harness.control.currentTime = 100
        harness.timer.start(.endOfChapter)
        #expect(harness.timer.remaining == 2600, "The track's end")
    }

    @Test func aSeekWithoutMediaStopsAChapterTimer() {
        let harness = Harness(timeline: chapters, at: 100)
        harness.timer.start(.endOfChapter)
        harness.control.timeline = nil
        harness.timer.didSeek(to: 0)
        #expect(harness.timer.isRunning == false)
        #expect(harness.timer.canRestart == false)
    }

    @Test func pausedEndOfChapterExpiresOnlyAtTheEndOfTheMedia() async {
        let harness = Harness(timeline: chapters, at: 100)
        harness.timer.start(.endOfChapter)
        harness.control.isPlaying = false
        harness.control.currentTime = 449
        harness.timer.didSeek(to: 449)
        harness.control.currentTime = 451
        await harness.advance(1)
        #expect(harness.timer.isRunning, "A seek may not have landed")

        harness.control.currentTime = 1800
        await harness.advance(1)
        #expect(harness.timer.isRunning == false)
        #expect(harness.control.pauseCount == 1)
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

    @Test func countsAddsAndSubtractsChapterTimeAtTheRate() {
        let harness = Harness(timeline: chapters, at: 100)
        harness.control.rate = 2
        harness.timer.start(.endOfChapter)
        #expect(harness.timer.remaining == 175)
        harness.timer.add(60)
        #expect(harness.timer.remaining == 235)
        harness.timer.subtract(200)
        #expect(harness.timer.remaining == 35)
        harness.timer.add(10_000)
        #expect(harness.timer.remaining == 850, "Capped at the end of the media")
    }

    /// Adding or subtracting chapter time changes the listening time by that much: the end walks over the tracks,
    /// so the gaps between them don't count. All start at 70; a negative change subtracts.
    @Test(
        arguments: [
            // Copilot's example: 30 s of the first track and 10 of the second, less 39.
            ([5...100, 110...200], 120, 1, -39, 1, 71),
            // 200 media seconds at 2× over four tracks, less 80 s, leaves 40: the end moves back across two gaps,
            // to 10 s past a third.
            ([0...100, 110...150, 160...250, 260...400], 300, 2, -80, 20, 120),
            // 30 s to the end of the first track, then 20 of the second.
            ([5...100, 110...200], 100, 1, 20, 50, 130),
            // Without gaps, as before.
            ([0...200], 120, 1, -39, 11, 81),
            ([0...200], 120, 1, 20, 70, 140),
        ] as [([ClosedRange<Double>], Double, Double, Double, Double, Double)])
    func adjustingChapterTimeSkipsGapsBetweenTracks(
        tracks: [ClosedRange<Double>], chapterEnd: Double, rate: Double, change: Double, left: Double, pause: Double
    ) async {
        let harness = Harness(timeline: gappedTimeline(tracks, chapterEnd: chapterEnd), at: 70)
        harness.control.rate = rate
        harness.timer.start(.endOfChapter)
        if change < 0 { harness.timer.subtract(-change) } else { harness.timer.add(change) }
        #expect(harness.timer.remaining == left)
        await harness.play(from: 70, to: pause - 1)
        #expect(harness.control.pauseCount == 0)
        await harness.play(from: pause - 1, to: pause)
        #expect(harness.control.pauseCount == 1)
    }

    @Test func chapterTimeAddedSurvivesSeeksWithinTheChapterOrTheAddedTime() async {
        let harness = Harness(timeline: chapters, at: 100)
        harness.timer.start(.endOfChapter)
        harness.timer.add(300)
        harness.control.currentTime = 90
        harness.timer.didSeek(to: 90)
        #expect(harness.timer.remaining == 660, "Still aims at 750")
        await harness.play(from: 440, to: 600)
        harness.control.currentTime = 597
        harness.timer.didSeek(to: 597)
        #expect(harness.timer.remaining == 153, "A resume rewind past the chapter's end keeps it")
        harness.control.currentTime = 1200
        harness.timer.didSeek(to: 1200)
        #expect(harness.timer.remaining == 600, "Another chapter drops it")
    }

    @Test func anotherItemsLoadRetargetsAChapterGoalAfresh() async {
        let harness = Harness(timeline: chapters, at: 400)
        harness.timer.start(.endOfChapter)
        harness.timer.add(300)
        await harness.play(from: 400, to: 600)
        harness.timer.itemDidChange("other")
        #expect(harness.timer.remaining == 150, "Until its load lands")
        harness.timer.didSeek(to: 600)
        #expect(harness.timer.remaining == 400, "Its chapter ends at 1000, not at 450 + 300")
        harness.control.currentTime = 590
        harness.timer.didSeek(to: 590)
        #expect(harness.timer.remaining == 410)
    }

    @Test(arguments: [(90.0, 101.0), (300, 450)])
    func chapterTimeSubtractedSurvivesASeekUntilItPassesIt(seek: Double, end: Double) async {
        let harness = Harness(timeline: chapters, at: 100)
        harness.timer.start(.endOfChapter)
        harness.timer.subtract(1000)
        harness.control.currentTime = seek
        harness.timer.didSeek(to: seek)
        #expect(harness.timer.remaining == end - seek, "Aims at 101 until a seek passes it")
        await harness.play(from: seek, to: end)
        #expect(harness.control.pauseCount == 1)
        #expect(harness.timer.canRestart == (end == 450), "Cut short only while it aims at 101")
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
        harness.timer.cancel()
        #expect(harness.control.volume == 1)
        #expect(harness.timer.isRunning == false)
        #expect(harness.timer.remaining == nil)
        #expect(harness.timer.isTicking == false)
        await harness.advance(60)
        #expect(harness.control.pauseCount == 0)
    }

    // MARK: - Reset

    @Test func resetRestoresTheAdjustedLengthAfterThreeSeconds() async {
        let harness = Harness()
        harness.timer.start(.duration(600))
        harness.timer.add(60)
        await harness.advance(3)
        #expect(harness.timer.reset() == false)
        #expect(harness.timer.remaining == 657)
        #expect(harness.feedback.resets == 0)

        await harness.advance(1)
        #expect(harness.timer.reset())
        #expect(harness.timer.remaining == 660)
        #expect(harness.feedback.resets == 1)
    }

    @Test func resetNeedsPlaybackAndCanBeSilent() async {
        let harness = Harness(options: SleepTimerOptions(playsResetFeedback: false))
        harness.timer.start(.duration(600))
        await harness.advance(5)
        #expect(harness.timer.reset())
        #expect(harness.feedback.resets == 0)
        await harness.advance(5)
        harness.control.isPlaying = false
        #expect(harness.timer.reset() == false)
        #expect(harness.timer.remaining == 595)
    }

    @Test func resetRecomputesTheChapterEnd() {
        let harness = Harness(timeline: chapters, at: 100)
        harness.timer.start(.endOfChapter)
        harness.control.currentTime = 445
        #expect(harness.timer.reset())
        #expect(harness.timer.remaining == 555)
    }

    @Test func resetDuringTheGracePeriodRestartsAndPlays() async {
        let harness = Harness()
        harness.timer.start(.duration(10))
        await harness.expire()
        #expect(harness.timer.canRestart)

        harness.clock.advance(by: .seconds(60))
        #expect(harness.timer.reset())
        #expect(harness.timer.mode == .duration(10))
        #expect(harness.timer.canRestart == false)
        await until { harness.control.plays == 1 }
        #expect(harness.control.seeks.isEmpty)
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

    @Test(arguments: GraceEnd.allCases)
    func noRestartOnceTheGracePeriodEnds(_ end: GraceEnd) async {
        let harness = Harness()
        harness.timer.itemDidChange("a")
        harness.timer.start(.duration(10))
        await harness.expire()
        harness.timer.itemDidChange("a")
        switch end {
        case .graceTask: await harness.endGrace()
        case .clockOnly: harness.clock.advance(by: .seconds(SleepTimer.gracePeriod))
        case .cancel: harness.timer.cancel()
        case .anotherItem: harness.timer.itemDidChange("b")
        }
        #expect(harness.timer.canRestart == (end == .clockOnly), "Published when the grace task runs")
        #expect(harness.shake.sensitivity == (end == .clockOnly ? .medium : nil))
        #expect(harness.timer.reset() == false)
        #expect(harness.timer.playbackWillStart() == 0)
        #expect(harness.timer.isRunning == false)
        #expect(harness.control.plays == 0)
    }

    @Test func aRunningTimerIgnoresPlayAndItemChanges() async {
        let harness = Harness()
        harness.timer.start(.duration(600))
        await harness.advance(5)
        #expect(harness.timer.playbackWillStart() == 0)
        harness.timer.itemDidChange("c")
        harness.timer.didSeek(to: 50)
        #expect(harness.timer.remaining == 595)
    }

    @Test func aLateTickCountsAtMostTwoIntervals() async {
        let harness = Harness()
        harness.timer.start(.duration(600))
        let ticks = harness.timer.tickCount
        harness.clock.advance(by: .seconds(30))
        await until { harness.timer.tickCount > ticks }
        #expect(harness.timer.remaining == 598)
    }

    @Test func deinitStopsTickingShakeDetectionAndRestoresTheVolume() async {
        let clock = ManualClock()
        let control = FakePlaybackControl()
        let shake = FakeShakeDetector()
        var timer: SleepTimer? = SleepTimer(
            control: control, feedback: FakeFeedback(), shakeDetector: shake, clock: clock,
            calendar: .gregorianUTC, tickInterval: .seconds(1))
        weak let weakTimer = timer
        timer?.start(.duration(30))
        #expect(control.volume == 0.5)
        await until { clock.sleeperCount == 1 }
        #expect(shake.sensitivity == .medium)

        timer = nil
        #expect(weakTimer == nil)
        #expect(shake.sensitivity == nil)
        await until { clock.sleeperCount == 0 && control.volume == 1 }
    }

    // MARK: - Shake to reset

    @Test func shakingResetsARunningOrExpiredTimer() async {
        let harness = Harness()
        harness.timer.start(.duration(10))
        await harness.advance(5)
        harness.shake.shake()
        #expect(harness.timer.remaining == 10)

        await harness.expire()
        #expect(harness.shake.sensitivity == .medium, "Detects during the grace period")
        harness.shake.shake()
        await until { harness.control.plays == 1 }
        #expect(harness.timer.isRunning)
        #expect(harness.feedback.resets == 2)
    }

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

    @Test func shakeDetectionStopsWhilePausedAndWhenCancelled() async {
        let harness = Harness()
        harness.timer.start(.duration(600))
        #expect(harness.shake.sensitivity == .medium)
        harness.control.isPlaying = false
        await harness.advance(1)
        #expect(harness.shake.sensitivity == nil)
        harness.control.isPlaying = true
        await harness.advance(1)
        #expect(harness.shake.sensitivity == .medium)
        #expect(harness.shake.starts == 2)

        harness.timer.cancel()
        #expect(harness.shake.sensitivity == nil)
    }

    @Test func noShakeDetectionAfterACutShortTimer() async {
        let harness = Harness()
        harness.timer.start(.duration(600))
        harness.timer.subtract(1000)
        await harness.advance(1)
        #expect(harness.control.pauseCount == 1)
        #expect(harness.shake.sensitivity == nil)
    }

    // MARK: - Automatic timer

    @Test func automaticTimerStartsInsideTheWindowUntilCancelled() throws {
        let harness = Harness(options: try autoOptions())
        #expect(harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 12, 0)) == 0)
        #expect(harness.timer.isRunning == false)
        #expect(harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 23, 0)) == 0)
        #expect(harness.timer.mode == .duration(10))
        #expect(harness.timer.isAutomatic)

        harness.timer.cancel(at: try makeDate(2026, 1, 15, 23, 5))
        _ = harness.timer.playbackWillStart(at: try makeDate(2026, 1, 16, 5, 59))
        #expect(harness.timer.isRunning == false, "Suppressed until the window ends")
        _ = harness.timer.playbackWillStart(at: try makeDate(2026, 1, 16, 22, 0))
        #expect(harness.timer.isAutomatic)
    }

    @Test(arguments: Move.allCases)
    func automaticTimerRewindsOnlyWherePlaybackPaused(_ move: Move) async throws {
        let harness = Harness(at: 1000, options: try autoOptions())
        harness.timer.itemDidChange("a")
        _ = harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 23, 0))
        await harness.expire()
        await harness.endGrace()
        switch move {
        case .none: harness.timer.itemDidChange("a")
        case .seek, .unreportedSeek: harness.control.currentTime = 5000
        case .anotherItem: harness.timer.itemDidChange("b")
        }
        if move == .seek { harness.timer.didSeek(to: 5000) }

        #expect(harness.timer.playbackWillStart(at: try makeDate(2026, 1, 16, 7, 30)) == (move == .none ? 300 : 0))
        #expect(harness.timer.isRunning == false, "Outside the window")
        #expect(harness.timer.playbackWillStart(at: try makeDate(2026, 1, 16, 7, 31)) == 0, "Consumed")
    }

    @Test func resetAfterAnAutomaticTimerRewindsAndPlays() async throws {
        let harness = Harness(timeline: chapters, at: 1000, options: try autoOptions())
        _ = harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 23, 0))
        await harness.expire()

        #expect(harness.timer.reset())
        #expect(harness.feedback.resets == 0, "Not until it plays")
        await until { harness.control.plays == 1 }
        #expect(harness.control.seeks == [700])
        #expect(harness.feedback.resets == 1)
        #expect(harness.timer.isAutomatic)
        #expect(harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 23, 11)) == 0)
    }

    @Test(arguments: [false, true])
    func aResetWhoseRewindFailsRestoresTheGracePeriodAndTheRewindOnTheSameItem(itemChanges: Bool) async throws {
        let harness = Harness(timeline: chapters, at: 1000, options: try autoOptions())
        _ = harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 23, 0))
        await harness.expire()
        harness.clock.advance(by: .seconds(60))
        harness.control.seeksLand = false
        harness.control.holdsSeeks = true
        #expect(harness.timer.reset())
        await until { harness.control.seeks == [700] }
        if itemChanges { harness.timer.itemDidChange("other") }
        await harness.control.finishSeek()
        #expect(harness.timer.isRunning == itemChanges, "Another item keeps the restarted timer")
        #expect(harness.control.plays == 0)
        #expect(harness.feedback.resets == 0)
        #expect(harness.timer.canRestart == !itemChanges)
        #expect(harness.shake.sensitivity == (itemChanges ? nil : .medium), "Shake to reset follows the grace period")

        harness.clock.advance(by: .seconds(60))
        await until { !harness.timer.canRestart }
        #expect(harness.timer.playbackWillStart(at: try makeDate(2026, 1, 16, 7, 30)) == (itemChanges ? 0 : 300))
    }

    /// A cancel, a start or another item, before a reset's rewind seek or during it, wins: no seek, or no play.
    @Test(arguments: ResetRace.allCases)
    func changesAroundAResetsRewindWin(_ race: ResetRace) async throws {
        let harness = Harness(timeline: chapters, at: 1000, options: try autoOptions())
        _ = harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 23, 0))
        await harness.expire()
        harness.control.holdsSeeks = true
        #expect(harness.timer.reset())
        let isDuring = race == .cancelDuring || race == .itemDuring
        if isDuring { await until { harness.control.seeks == [700] } }
        switch race {
        case .cancelBefore, .cancelDuring: harness.timer.cancel()
        case .startBefore: harness.timer.start(.duration(600))
        case .itemBefore, .itemDuring: harness.timer.itemDidChange("other")
        }
        await harness.control.finishSeek()
        await Task { @MainActor in }.value  // Queued after the reset's task, so that has run.
        #expect(harness.control.seeks == (isDuring ? [700] : []))
        #expect(harness.control.currentTime == (isDuring ? 700 : 1000))
        #expect(harness.control.plays == 0)
        #expect(harness.feedback.resets == 0)
        #expect(harness.timer.isRunning == (race != .cancelBefore && race != .cancelDuring))
    }

    @Test func aResetAtTheEndOfTheMediaWaitsForItsRewindThenPlays() async throws {
        let harness = Harness(timeline: chapters, at: 1700, options: try autoOptions(mode: .endOfChapter))
        _ = harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 23, 0))
        await harness.play(from: 1700, to: 1800)
        #expect(harness.control.pauseCount == 1)
        harness.control.holdsSeeks = true
        #expect(harness.timer.reset())
        await until { harness.control.seeks == [1500] }
        await harness.advance(3)
        #expect(harness.timer.remaining == 300, "Not at the end, where playback still is")
        await harness.control.finishSeek()
        #expect(harness.control.plays == 1)
        #expect(harness.timer.isRunning)
    }

    @Test func theAutomaticRewindStartsWhereTheFadeBegan() async throws {
        let harness = Harness(at: 1000, options: try autoOptions(mode: .duration(70)))
        _ = harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 23, 0))
        await harness.play(from: 1000, to: 1070)
        await until { harness.control.currentTime == 1010 }
        await harness.endGrace()
        #expect(harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 23, 20)) == 300)
        #expect(harness.timer.isAutomatic, "And the next automatic timer starts")
    }

    /// A play during the expiry's seek takes no automatic rewind; a manual start keeps it, as does a failed seek
    /// unless a user's seek superseded it.
    @Test(arguments: ExpirySeek.allCases)
    func theAutomaticRewindAfterTheExpirySeek(_ event: ExpirySeek) async throws {
        let harness = Harness(at: 1000, options: try autoOptions(mode: .duration(70)))
        _ = harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 23, 0))
        harness.control.holdsSeeks = event != .failure
        harness.control.seeksLand = event != .failure && event != .userSeek
        await harness.play(from: 1000, to: 1070)
        await until { harness.control.seeks == [1010] }
        if event == .play { #expect(harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 23, 2)) == 0) }
        if event == .manualStart { harness.timer.start(.duration(600)) }
        if event == .userSeek { harness.control.currentTime = 5000 }
        await harness.control.finishSeek()
        let position: Double = event == .failure ? 1070 : event == .userSeek ? 5000 : 1010
        await until { harness.control.currentTime == position }
        harness.timer.cancel()
        let rewind: TimeInterval = event == .play || event == .userSeek ? 0 : 300
        #expect(harness.timer.playbackWillStart(at: try makeDate(2026, 1, 16, 7, 30)) == rewind)
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

    @Test func pendingRewindOutlivesAManualTimer() async throws {
        let harness = Harness(options: try autoOptions())
        _ = harness.timer.playbackWillStart(at: try makeDate(2026, 1, 15, 23, 0))
        await harness.expire()
        harness.timer.start(.duration(60))
        #expect(harness.timer.isAutomatic == false)
        harness.timer.cancel()
        #expect(harness.timer.playbackWillStart(at: try makeDate(2026, 1, 16, 7, 0)) == 300)
    }

    @Test func manualTimerDoesNotRewind() async throws {
        let harness = Harness(options: try autoOptions())
        harness.timer.start(.duration(5))
        await harness.expire()
        await harness.endGrace()
        #expect(harness.timer.playbackWillStart(at: try makeDate(2026, 1, 16, 7, 0)) == 0)
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
