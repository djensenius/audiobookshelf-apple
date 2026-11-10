import ABSCore
import Foundation
import Observation

/// The sleep timer: pauses playback after a duration or at the end of the chapter.
///
/// - A duration counts down only while audio plays (legacy iOS); an end-of-chapter timer pauses when playback
///   reaches the chapter's end, in wall-clock seconds at the current rate.
/// - The volume fades out over the last ``fadeDuration`` seconds and is restored after the pause.
/// - The chime plays once per run, ``chimeLeadTime`` seconds before the end; a run that starts with less left
///   never chimes.
/// - For ``gracePeriod`` seconds after the timer pauses playback, shaking or playing again restarts it.
/// - Shake to reset restarts a running timer while audio plays.
/// - An automatic timer starts when playback starts inside the ``AutoSleepPolicy`` window.
///
/// The playback coordinator calls ``playbackWillStart(at:)`` before every play and ``didSeek(to:)`` after seeks,
/// chapter skips and item loads.
@MainActor
@Observable
public final class SleepTimer {
    /// The volume fades over the last minute (legacy iOS `AudioPlayer.startFadeOut`, Android `SleepTimerManager`).
    public static let fadeDuration: TimeInterval = 60
    /// The chime plays 30 seconds before the end (Android `SleepTimerManager`).
    public static let chimeLeadTime: TimeInterval = 30
    /// The Android `SLEEP_TIMER_WAKE_UP_EXPIRATION`.
    public static let gracePeriod: TimeInterval = 120
    /// A running duration timer resets only after this many seconds (Android `checkShouldResetSleepTimer`).
    static let resetGuard: TimeInterval = 3
    /// An end-of-chapter timer started closer than this to the chapter's end waits for the next one.
    static let minimumChapterRemaining: TimeInterval = 10
    /// Subtracting time leaves at least this much.
    static let minimumRemaining: TimeInterval = 1

    /// The running timer's mode; a duration includes added and subtracted time. `nil` when no timer runs.
    public private(set) var mode: SleepTimerMode?
    /// Seconds until the timer pauses playback, or `nil` when no timer runs.
    public private(set) var remaining: TimeInterval?
    /// Whether the running timer started automatically.
    public private(set) var isAutomatic = false
    /// Whether the timer recently paused playback and a shake or play would restart it.
    public private(set) var canRestart = false
    public var isRunning: Bool { mode != nil }
    /// Takes effect at the next tick; changes to the shake sensitivity apply immediately.
    public var options: SleepTimerOptions {
        didSet { updateShakeDetection() }
    }

    private enum Goal {
        case length(TimeInterval)
        case chapterEnd(Double)
    }

    private enum Chime {
        /// Too close to the end when the run started; arms once more than the lead time is left.
        case waiting
        case armed
        case played
    }

    private struct Run {
        var goal: Goal
        var isAutomatic: Bool
        /// Seconds of playback since the run started.
        var elapsed: TimeInterval = 0
        var chime = Chime.waiting
        /// Subtracting time ran into the minimum; the run doesn't restart after it expires (Android).
        var wasCutShort = false

        var mode: SleepTimerMode {
            switch goal {
            case .length(let length): .duration(length)
            case .chapterEnd: .endOfChapter
            }
        }
    }

    @ObservationIgnored private let control: any SleepTimerPlaybackControl
    @ObservationIgnored private let feedback: any SleepTimerFeedback
    @ObservationIgnored private let shakeDetector: (any ShakeDetecting)?
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let tickInterval: Duration
    @ObservationIgnored private var run: Run?
    /// The run that last expired, while it can restart.
    @ObservationIgnored private var expiredRun: Run?
    @ObservationIgnored private var graceHasEnded: (@Sendable () -> Bool)?
    /// Seconds to rewind at the next play, after an automatic timer expired.
    @ObservationIgnored private var pendingRewind: TimeInterval?
    @ObservationIgnored private var autoSleepSuppressedUntil: Date?
    @ObservationIgnored private var appliedVolume: Float = 1
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var detectingSensitivity: ShakeSensitivity?
    /// Ticks so far, for tests.
    @ObservationIgnored private(set) var tickCount = 0
    var isTicking: Bool { tickTask != nil }

    /// - Parameters:
    ///   - shakeDetector: Pass ``ShakeDetector`` on iOS; `nil` disables shake to reset.
    ///   - tickInterval: How often the countdown, fade and chime update.
    public init(
        control: any SleepTimerPlaybackControl,
        feedback: any SleepTimerFeedback = SystemSleepTimerFeedback(),
        shakeDetector: (any ShakeDetecting)? = nil,
        options: SleepTimerOptions = SleepTimerOptions(),
        clock: any Clock<Duration> = ContinuousClock(),
        calendar: Calendar = .autoupdatingCurrent,
        tickInterval: Duration = .milliseconds(500)
    ) {
        self.control = control
        self.feedback = feedback
        self.shakeDetector = shakeDetector
        self.options = options
        self.clock = clock
        self.calendar = calendar
        self.tickInterval = tickInterval
    }

    isolated deinit {
        tickTask?.cancel()
        graceTask?.cancel()
        if detectingSensitivity != nil { shakeDetector?.stop() }
    }

    // MARK: - Commands

    /// Starts a timer, replacing any running one. Returns `false`, changing nothing, for a duration that isn't
    /// positive or, for end of chapter, without a chapter or track end ahead.
    @discardableResult
    public func start(_ mode: SleepTimerMode) -> Bool {
        guard begin(mode, isAutomatic: false, at: control.currentTime) else { return false }
        pendingRewind = nil
        return true
    }

    /// Cancels the timer and restores the volume. Cancelling an automatic timer keeps it from starting again
    /// until its window ends (Android `cancelSleepTimer`).
    public func cancel(at date: Date = .now) {
        if (run ?? expiredRun)?.isAutomatic == true {
            autoSleepSuppressedUntil = options.autoSleep.window(containing: date, calendar: calendar)?.end
        }
        stopRun()
        endGrace()
        pendingRewind = nil
        applyVolume(1)
        publish(remaining: nil)
        updateShakeDetection()
    }

    /// Adds `seconds` of listening time. For end of chapter, the end moves by `seconds` at the current rate,
    /// up to the end of the media.
    public func add(_ seconds: TimeInterval) {
        guard var run, seconds.isFinite, seconds > 0 else { return }
        switch run.goal {
        case .length(let length):
            run.goal = .length(length + seconds)
        case .chapterEnd(let end):
            let limit = control.timeline?.duration ?? .infinity
            run.goal = .chapterEnd(min(end + seconds * rate, max(limit, end)))
        }
        run.wasCutShort = false
        update(run)
    }

    /// Removes `seconds`, leaving at least ``minimumRemaining``.
    public func subtract(_ seconds: TimeInterval) {
        guard var run, seconds.isFinite, seconds > 0 else { return }
        let left = remaining(of: run)
        let newLeft = min(left, max(left - seconds, Self.minimumRemaining))
        if left - seconds <= Self.minimumRemaining { run.wasCutShort = true }
        switch run.goal {
        case .length(let length): run.goal = .length(length - (left - newLeft))
        case .chapterEnd(let end): run.goal = .chapterEnd(end - (left - newLeft) * rate)
        }
        update(run)
    }

    /// Shake to reset. A running timer restarts while audio plays (a duration only after ``resetGuard``
    /// seconds); during the grace period the expired timer restarts and playback resumes, after the automatic
    /// rewind. Returns whether it reset.
    @discardableResult
    public func reset() -> Bool {
        if let run {
            if case .length = run.goal, run.elapsed <= Self.resetGuard { return false }
            guard control.isPlaying, begin(run.mode, isAutomatic: run.isAutomatic, at: control.currentTime) else {
                return false
            }
        } else if let expiredRun = restartableRun {
            let rewind = pendingRewind ?? 0
            guard begin(expiredRun.mode, isAutomatic: expiredRun.isAutomatic, at: time(rewoundBy: rewind)) else {
                return false
            }
            pendingRewind = nil
            control.play(rewindingBy: rewind)
        } else {
            return false
        }
        if options.playsResetFeedback { feedback.playResetFeedback() }
        return true
    }

    /// Call before playback starts. Restarts a timer that expired during the grace period, or starts the
    /// automatic timer inside its window. Returns the seconds to rewind before playing (after an automatic
    /// timer expired), which is consumed.
    public func playbackWillStart(at date: Date = .now) -> TimeInterval {
        let rewind = pendingRewind ?? 0
        pendingRewind = nil
        guard run == nil else { return rewind }
        let time = time(rewoundBy: rewind)
        if let expiredRun = restartableRun {
            if begin(expiredRun.mode, isAutomatic: expiredRun.isAutomatic, at: time), options.playsResetFeedback {
                feedback.playResetFeedback()
            }
        } else if shouldStartAutomatically(at: date) {
            begin(options.autoSleep.mode, isAutomatic: true, at: time)
        }
        return rewind
    }

    /// Call once a seek, chapter skip or item load lands at `time`. An end-of-chapter timer moves to the end of
    /// the chapter now playing.
    public func didSeek(to time: Double) {
        guard var run, case .chapterEnd = run.goal, let end = chapterEnd(at: time, skippingShortRemainder: false)
        else { return }
        run.goal = .chapterEnd(end)
        run.wasCutShort = false
        update(run, remaining: (end - time) / rate)
    }

    // MARK: - Running

    @discardableResult
    private func begin(_ mode: SleepTimerMode, isAutomatic: Bool, at time: Double) -> Bool {
        let goal: Goal
        switch mode {
        case .duration(let length):
            guard length.isFinite, length > 0 else { return false }
            goal = .length(length)
        case .endOfChapter:
            guard let end = chapterEnd(at: time, skippingShortRemainder: true) else { return false }
            goal = .chapterEnd(end)
        }
        endGrace()
        var run = Run(goal: goal, isAutomatic: isAutomatic)
        let left = Self.remaining(of: run, at: time, rate: rate)
        if left > Self.chimeLeadTime { run.chime = .armed }
        self.run = run
        applyVolume(fadeVolume(left))
        startTicking()
        publish(remaining: left)
        updateShakeDetection()
        return true
    }

    private func update(_ run: Run, remaining: TimeInterval? = nil) {
        var run = run
        let left = remaining ?? self.remaining(of: run)
        if run.chime == .waiting, left > Self.chimeLeadTime { run.chime = .armed }
        self.run = run
        applyVolume(fadeVolume(left))
        publish(remaining: left)
    }

    private func tick() {
        tickCount += 1
        guard var run else { return }
        let isPlaying = control.isPlaying
        if isPlaying { run.elapsed += Self.seconds(tickInterval) }
        let left = remaining(of: run)
        // While paused only the end of the media expires a timer: a seek may not have landed yet.
        if left <= 0, isPlaying || control.currentTime >= (control.timeline?.duration ?? 0) {
            self.run = run
            expire()
            return
        }
        if isPlaying, run.chime == .armed, left <= Self.chimeLeadTime {
            run.chime = .played
            if options.playsAlmostDoneChime { feedback.playChime() }
        }
        self.run = run
        applyVolume(fadeVolume(left))
        publish(remaining: max(left, 0))
    }

    private func expire() {
        guard let run else { return }
        control.pause()
        applyVolume(1)
        if run.isAutomatic, let rewind = options.autoSleep.rewindOnExpiry { pendingRewind = rewind }
        stopRun()
        if !run.wasCutShort { startGrace(for: run) }
        publish(remaining: nil)
        updateShakeDetection()
    }

    private func stopRun() {
        run = nil
        tickTask?.cancel()
        tickTask = nil
    }

    private func startTicking() {
        guard tickTask == nil else { return }
        // A local opens the existential; passing the property directly doesn't compile with Foundation imported.
        let clock = clock
        tickTask = Self.schedule(on: clock, every: tickInterval, repeats: true, owner: self) { $0.tick() }
    }

    private func startGrace(for run: Run) {
        endGrace()
        expiredRun = run
        let clock = clock
        let grace = Duration.seconds(Self.gracePeriod)
        graceHasEnded = Self.deadline(on: clock, after: grace)
        graceTask = Self.schedule(on: clock, every: grace, repeats: false, owner: self) { $0.graceDidEnd() }
    }

    private func graceDidEnd() {
        endGrace()
        publish(remaining: remaining)
        updateShakeDetection()
    }

    private func endGrace() {
        expiredRun = nil
        graceHasEnded = nil
        graceTask?.cancel()
        graceTask = nil
    }

    /// The expired run, unless the grace period is over (the grace task may not have run yet after a suspension).
    private var restartableRun: Run? {
        guard let expiredRun, let graceHasEnded, !graceHasEnded() else { return nil }
        return expiredRun
    }

    private func shouldStartAutomatically(at date: Date) -> Bool {
        guard options.autoSleep.shouldStart(at: date, calendar: calendar) else { return false }
        if let until = autoSleepSuppressedUntil {
            guard date >= until else { return false }
            autoSleepSuppressedUntil = nil
        }
        return true
    }

    // MARK: - Time

    /// The playback rate, or `1` when the control reports an unusable one (legacy iOS).
    private var rate: Double {
        let rate = control.rate
        return rate.isFinite && rate > 0 ? rate : 1
    }

    private func remaining(of run: Run) -> TimeInterval {
        Self.remaining(of: run, at: control.currentTime, rate: rate)
    }

    private static func remaining(of run: Run, at time: Double, rate: Double) -> TimeInterval {
        switch run.goal {
        case .length(let length): length - run.elapsed
        case .chapterEnd(let end): (end - time) / rate
        }
    }

    private func time(rewoundBy seconds: TimeInterval) -> Double {
        control.timeline?.jumpBackward(from: control.currentTime, by: seconds) ?? control.currentTime
    }

    /// The end of the chapter playing at `time` (or of the gap before the next chapter; of the track without
    /// chapters). When starting with less than ``minimumChapterRemaining`` seconds left, the end of the next one
    /// (Android `getChapterEndTime`).
    private func chapterEnd(at time: Double, skippingShortRemainder: Bool) -> Double? {
        guard let timeline = control.timeline, let end = Self.segmentEnd(in: timeline, at: time), end > time else {
            return nil
        }
        if skippingShortRemainder, (end - time) / rate < Self.minimumChapterRemaining,
            let next = Self.segmentEnd(in: timeline, at: end), next > end
        {
            return next
        }
        return end
    }

    private static func segmentEnd(in timeline: PlaybackTimeline, at time: Double) -> Double? {
        guard timeline.chapters.isEmpty else {
            return timeline.endOfChapter(at: time) ?? timeline.nextChapterStart(from: time)
        }
        return timeline.position(at: time).map { timeline.tracks[$0.trackIndex].playbackEnd }
    }

    // MARK: - Output

    /// Linear from full volume ``fadeDuration`` seconds before the end to silence at the end.
    private func fadeVolume(_ remaining: TimeInterval) -> Float {
        guard options.fadesOut else { return 1 }
        return Float(min(max(remaining / Self.fadeDuration, 0), 1))
    }

    private func applyVolume(_ volume: Float) {
        guard volume != appliedVolume else { return }
        appliedVolume = volume
        control.setVolume(volume)
    }

    private func publish(remaining left: TimeInterval?) {
        let newMode = run?.mode
        if mode != newMode { mode = newMode }
        if remaining != left { remaining = left }
        let automatic = run?.isAutomatic ?? false
        if isAutomatic != automatic { isAutomatic = automatic }
        let restartable = run == nil && expiredRun != nil
        if canRestart != restartable { canRestart = restartable }
    }

    private func updateShakeDetection() {
        let sensitivity = run != nil || expiredRun != nil ? options.shakeSensitivity : nil
        guard let shakeDetector, sensitivity != detectingSensitivity else { return }
        detectingSensitivity = sensitivity
        if let sensitivity {
            shakeDetector.start(sensitivity: sensitivity) { [weak self] in self?.reset() }
        } else {
            shakeDetector.stop()
        }
    }

    // MARK: - Scheduling

    /// Runs `body` on the main actor at absolute deadlines `interval` apart, starting `interval` from now.
    /// Deadlines missed while the app was suspended are skipped rather than run in a burst.
    private static func schedule<C: Clock<Duration>>(
        on clock: C, every interval: Duration, repeats: Bool, owner: SleepTimer,
        _ body: @escaping @MainActor (SleepTimer) -> Void
    ) -> Task<Void, Never> {
        // The first deadline is fixed now, so a test clock advanced before the task runs still wakes it.
        let first = clock.now.advanced(by: interval)
        return Task { [weak owner] in
            var deadline = first
            while true {
                do {
                    try await clock.sleep(until: deadline, tolerance: nil)
                } catch {
                    return
                }
                guard !Task.isCancelled, let owner else { return }
                body(owner)
                guard repeats else { return }
                deadline = max(deadline.advanced(by: interval), clock.now)
            }
        }
    }

    private static func deadline<C: Clock<Duration>>(on clock: C, after interval: Duration) -> @Sendable () -> Bool {
        let deadline = clock.now.advanced(by: interval)
        return { clock.now >= deadline }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
