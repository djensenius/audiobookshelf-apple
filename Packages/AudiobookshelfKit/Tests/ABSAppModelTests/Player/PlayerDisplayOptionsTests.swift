import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

@Suite struct PlayerDisplayOptionsTests {
    private static let legacyDefaults = PlayerDisplayOptions(
        chapterTrack: true, totalTrack: true, scalesElapsedTimeBySpeed: true, isLocked: false)

    // MARK: Times

    @Test func scalingDividesTheElapsedTimeByTheRate() {
        let times = Self.legacyDefaults.times(elapsed: 150, duration: 400, rate: 1.5)
        #expect(times.elapsed == 100)
        #expect(times.remaining == 250 / 1.5)
        // Progress stays in media time.
        #expect(times.progress == 0.375)
    }

    /// Like legacy `timeRemaining`, only the elapsed time follows the option: the remaining time is
    /// always wall-clock time.
    @Test func withoutScalingOnlyTheRemainingTimeFollowsTheRate() {
        var options = Self.legacyDefaults
        options.scalesElapsedTimeBySpeed = false
        let times = options.times(elapsed: 150, duration: 400, rate: 2)
        #expect(times.elapsed == 150)
        #expect(times.remaining == 125)
        #expect(times.progress == 0.375)
    }

    @Test func unusableRatesCountAsOneAndTimesAreClamped() {
        let options = Self.legacyDefaults
        for rate in [0, -1, .nan, .infinity] {
            #expect(
                options.times(elapsed: 100, duration: 400, rate: rate)
                    == .init(progress: 0.25, elapsed: 100, remaining: 300))
        }
        #expect(options.times(elapsed: 500, duration: 400, rate: 1) == .init(progress: 1, elapsed: 400, remaining: 0))
        #expect(options.times(elapsed: -5, duration: 400, rate: 1) == .init(progress: 0, elapsed: 0, remaining: 400))
        #expect(options.times(elapsed: .nan, duration: .nan, rate: 1) == .init(progress: 0, elapsed: 0, remaining: 0))
    }

    // MARK: Tracks

    @Test func theTotalTrackShowsOnlyAlongsideAChapterTrack() {
        var options = Self.legacyDefaults
        #expect(options.showsTotalTrack(mainTrackIsChapter: true))
        #expect(!options.showsTotalTrack(mainTrackIsChapter: false))
        options.totalTrack = false
        #expect(!options.showsTotalTrack(mainTrackIsChapter: true))
        options.totalTrack = true
        options.chapterTrack = false
        #expect(!options.showsTotalTrack(mainTrackIsChapter: true))
    }

    /// Legacy `clickMenuAction`: one of the two tracks always stays on.
    @Test func turningOneTrackOffTurnsTheOtherOn() {
        var options = PlayerDisplayOptions(
            chapterTrack: true, totalTrack: false, scalesElapsedTimeBySpeed: true, isLocked: false)
        options.toggleChapterTrack()
        #expect(!options.chapterTrack)
        #expect(options.totalTrack)

        options.toggleTotalTrack()
        #expect(!options.totalTrack)
        #expect(options.chapterTrack)

        // Turning one on leaves the other alone.
        options.toggleTotalTrack()
        #expect(options.totalTrack)
        #expect(options.chapterTrack)
    }

    // MARK: Lock

    @Test func lockHidesTheSkipControlsAndTheScrubber() {
        var options = Self.legacyDefaults
        #expect(options.showsSkipControls)
        #expect(options.allowsScrubbing)
        options.isLocked = true
        #expect(!options.showsSkipControls)
        #expect(!options.allowsScrubbing)
    }
}
