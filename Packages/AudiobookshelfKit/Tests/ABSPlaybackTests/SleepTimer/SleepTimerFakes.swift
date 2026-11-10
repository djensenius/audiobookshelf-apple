import ABSCore
import Foundation
import Testing

@testable import ABSPlayback

/// Playback that moves only when a test says so. `pause()` stops it and `play()` starts it; seeks land at once
/// unless held, and the latest seek wins, as in the engine.
@MainActor
final class FakePlaybackControl: SleepTimerPlaybackControl {
    var isPlaying = true
    var currentTime: Double = 0
    var rate: Double = 1
    var timeline: PlaybackTimeline?
    private(set) var volumes: [Float] = []
    private(set) var pauseCount = 0
    private(set) var plays = 0
    private(set) var seeks: [Double] = []
    /// Whether seeks complete.
    var seeksLand = true
    /// Whether seeks wait for ``finishSeek()``.
    var holdsSeeks = false
    /// Where a seek of the user's in flight lands.
    var userSeekTarget: Double?
    private var heldSeek: CheckedContinuation<Void, Never>?
    /// Where the latest of the timer's seeks in flight lands.
    private var seekTarget: Double?
    /// The volume when playback was last paused.
    private(set) var volumeAtPause: Float?

    init(timeline: PlaybackTimeline? = nil, at time: Double = 0) {
        self.timeline = timeline
        currentTime = time
    }

    var volume: Float { volumes.last ?? 1 }
    var pendingSeekTarget: Double? { userSeekTarget ?? seekTarget }

    func pause() {
        pauseCount += 1
        volumeAtPause = volume
        isPlaying = false
    }

    func play() {
        plays += 1
        isPlaying = true
    }

    func seek(to time: Double) async -> Double? {
        seeks.append(time)
        let generation = seeks.count
        seekTarget = time
        if holdsSeeks {
            await withCheckedContinuation { heldSeek = $0 }
            heldSeek = nil
        }
        guard generation == seeks.count else { return nil }
        seekTarget = nil
        guard seeksLand else { return nil }
        currentTime = time
        return time
    }

    /// Lets a held seek return, and waits until its caller has carried on: a resumed continuation can reach the main
    /// actor after jobs queued later, so a barrier task wouldn't do.
    func finishSeek() async {
        heldSeek?.resume()
        await until { heldSeek == nil }
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

/// Yields until `condition` holds; the timer's tasks need a few turns of the executors to run. Never sleeps. Bounded
/// by wall-clock time, not yields: a loaded machine can starve the pool threads that resume ``ManualClock`` sleepers.
@MainActor
func until(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition(), ContinuousClock.now < deadline { await Task.yield() }
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
