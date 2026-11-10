import ABSCore
import Foundation
import Testing

@testable import ABSPlayback

/// Playback that moves only when a test says so. `pause()` stops it; `play(rewindingBy:)` rewinds and plays.
@MainActor
final class FakePlaybackControl: SleepTimerPlaybackControl {
    var isPlaying = true
    var currentTime: Double = 0
    var rate: Double = 1
    var timeline: PlaybackTimeline?
    private(set) var volumes: [Float] = []
    private(set) var pauseCount = 0
    private(set) var plays: [Double] = []
    /// The volume when playback was last paused.
    private(set) var volumeAtPause: Float?

    init(timeline: PlaybackTimeline? = nil, at time: Double = 0) {
        self.timeline = timeline
        currentTime = time
    }

    var volume: Float { volumes.last ?? 1 }

    func pause() {
        pauseCount += 1
        volumeAtPause = volume
        isPlaying = false
    }

    func play(rewindingBy seconds: Double) {
        plays.append(seconds)
        currentTime = max(currentTime - seconds, 0)
        isPlaying = true
    }

    func setVolume(_ volume: Float) {
        volumes.append(volume)
    }
}

@MainActor
final class FakeFeedback: SleepTimerFeedback {
    private(set) var chimes = 0
    private(set) var resets = 0

    func playChime() { chimes += 1 }
    func playResetFeedback() { resets += 1 }
}

@MainActor
final class FakeShakeDetector: ShakeDetecting {
    private(set) var sensitivity: ShakeSensitivity?
    private(set) var starts = 0
    private var onShake: (@MainActor () -> Void)?

    func start(sensitivity: ShakeSensitivity, onShake: @escaping @MainActor () -> Void) {
        starts += 1
        self.sensitivity = sensitivity
        self.onShake = onShake
    }

    func stop() {
        sensitivity = nil
        onShake = nil
    }

    func shake() { onShake?() }
}

/// Yields until `condition` holds; the timer's tasks need a few turns of the executors to run. Never sleeps.
@MainActor
func until(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<100_000 where !condition() {
        await Task.yield()
    }
    if !condition() { Issue.record("Condition never held", sourceLocation: sourceLocation) }
}

/// Advances `clock` one second at a time, letting `timer` tick after each step (its tick interval is 1 s).
@MainActor
func advanceTicking(_ clock: ManualClock, _ timer: SleepTimer, seconds: Int) async {
    for _ in 0..<seconds {
        let ticks = timer.tickCount
        let wasTicking = timer.isTicking
        clock.advance(by: .seconds(1))
        if wasTicking { await until { timer.tickCount > ticks } }
    }
}

extension Calendar {
    /// Gregorian in UTC, so tests don't depend on the machine's time zone.
    static let gregorianUTC: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()
}

/// A date from wall-clock components in `calendar`.
func makeDate(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, in calendar: Calendar = .gregorianUTC
) throws -> Date {
    try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
}
