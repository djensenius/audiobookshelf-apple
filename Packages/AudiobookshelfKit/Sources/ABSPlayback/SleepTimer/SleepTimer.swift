import ABSCore
import Foundation
import Observation

/// The sleep timer: pauses playback after a duration or at the end of the chapter.
///
/// - A duration counts down only while audio plays (legacy iOS); an end-of-chapter timer pauses when playback
///   reaches the chapter's end, in wall-clock seconds at the current rate.
/// - The volume fades out over the last ``fadeDuration`` seconds and is restored after the pause. A duration
///   timer then seeks back to where the fade began (legacy iOS `AudioPlayer.startFadeOut`).
/// - The chime plays once per run, ``chimeLeadTime`` seconds before the end; a run that starts with less left,
///   or jumps past that moment, never chimes.
/// - For ``gracePeriod`` seconds after the timer pauses playback, shaking or playing the same item restarts it.
///   Once paused in the background iOS likely suspends the app, so a shake probably only works in the foreground
///   (to be checked on a device).
/// - Shake to reset restarts a running timer while audio plays.
/// - An automatic timer starts when playback starts inside the ``AutoSleepPolicy`` window.
///
/// The playback coordinator (#52) conforms to ``SleepTimerPlaybackControl`` and calls:
/// - ``itemDidChange(_:)`` when another item loads;
/// - ``playbackWillStart(at:)`` before every play, before its resume seek (AutoRewind), adding what it returns to
///   that rewind;
/// - ``didSeek(to:)`` synchronously once a seek, chapter skip, resume rewind or item load lands (right after the
///   `await`). A tick treats a jump nobody reported as a seek.
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
    /// A position change this much beyond what playback could do between ticks is a seek.
    static let seekThreshold: TimeInterval = 2
    /// A seek this far back into the chapter before keeps an end-of-chapter goal (the AutoRewind maximum).
    static let maximumResumeRewind: TimeInterval = 30

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
        /// The end of the chapter (or gap, or track), moved by added and subtracted media seconds.
        case chapterEnd(segmentEnd: Double, offset: Double)
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
        /// Where a duration run's fade began, rewound to after it expires.
        var fadeStart: Double?

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
    /// Seconds on the clock since `init`.
    @ObservationIgnored private let now: @Sendable () -> TimeInterval
    @ObservationIgnored private var run: Run?
    /// The run that last expired, while it can restart.
    @ObservationIgnored private var expiredRun: Run?
    /// When the grace period ends, in ``now`` seconds; checked directly, as the grace task may not have run.
    @ObservationIgnored private var graceEnd: TimeInterval?
    /// The automatic rewind for the next play, while playback is still where the automatic timer paused it.
    @ObservationIgnored private var pendingRewind: (seconds: TimeInterval, at: Double)?
    @ObservationIgnored private var itemID: String?
    /// The position and ``now`` at the last tick, seek or start, to spot seeks nobody reported.
    @ObservationIgnored private var lastPosition: Double?
    @ObservationIgnored private var lastTick: TimeInterval = 0
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
        now = Self.stopwatch(on: clock)
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
        begin(mode, isAutomatic: false, at: control.currentTime)
    }

    /// Cancels the timer and restores the volume. Cancelling an automatic timer keeps it from starting again
    /// until its window ends (Android `cancelSleepTimer`). A pending rewind stays: it belongs to the position.
    public func cancel(at date: Date = .now) {
        if (run ?? expiredRun)?.isAutomatic == true {
            autoSleepSuppressedUntil = options.autoSleep.window(containing: date, calendar: calendar)?.end
        }
        endGrace()
        stopRun()
    }

    /// Adds `seconds` of listening time. For end of chapter, the end moves by `seconds` at the current rate,
    /// up to the end of the media. Unlike Android, a duration isn't capped at the media left: it only counts
    /// down while audio plays.
    public func add(_ seconds: TimeInterval) {
        guard var run, seconds.isFinite, seconds > 0 else { return }
        switch run.goal {
        case .length(let length):
            run.goal = .length(length + seconds)
        case .chapterEnd(let segmentEnd, let offset):
            let limit = max(control.timeline?.duration ?? .infinity, segmentEnd + offset)
            let end = min(segmentEnd + offset + seconds * rate, limit)
            run.goal = .chapterEnd(segmentEnd: segmentEnd, offset: end - segmentEnd)
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
        case .chapterEnd(let segmentEnd, let offset):
            run.goal = .chapterEnd(segmentEnd: segmentEnd, offset: offset - (left - newLeft) * rate)
        }
        update(run)
    }

    /// Shake to reset. A running timer restarts while audio plays (a duration only after ``resetGuard``
    /// seconds); during the grace period the expired timer restarts and playback resumes after the pending
    /// rewind, with the reset feedback once it plays. Returns whether it reset.
    @discardableResult
    public func reset() -> Bool {
        if let run {
            if case .length = run.goal, run.elapsed <= Self.resetGuard { return false }
            guard control.isPlaying, begin(run.mode, isAutomatic: run.isAutomatic, at: control.currentTime) else {
                return false
            }
            if options.playsResetFeedback { feedback.playResetFeedback() }
            return true
        }
        guard let expiredRun = restartableRun else { return false }
        let time = time(rewoundBy: takeRewind())
        guard begin(expiredRun.mode, isAutomatic: expiredRun.isAutomatic, at: time) else { return false }
        let target = time < control.currentTime ? time : nil
        Task { [weak self] in await self?.resume(rewindingTo: target) }
        return true
    }

    /// Call before playback starts, and before the resume seek. Restarts a timer that expired during the grace
    /// period, or starts the automatic timer inside its window. Returns the seconds to rewind before playing,
    /// which are consumed: the automatic rewind, if playback is still where the automatic timer paused it.
    public func playbackWillStart(at date: Date = .now) -> TimeInterval {
        let rewind = takeRewind()
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

    /// Call when another item loads (`nil` when none): an expired timer restarts, and its rewind applies, only on
    /// the item it paused (Android `handleMediaPlayEvent` compares sessions). A running timer keeps running. For a
    /// podcast, pass an ID combining the item and the episode.
    public func itemDidChange(_ itemID: String?) {
        guard itemID != self.itemID else { return }
        self.itemID = itemID
        pendingRewind = nil
        endGrace()
        publish(remaining: remaining)
        updateShakeDetection()
    }

    /// Call once a seek, chapter skip, rewind or item load lands at `time`. An end-of-chapter timer moves to the
    /// end of the chapter now playing (dropping added or subtracted time), or of the media; without media it
    /// stops. A seek within the chapter, or just before it (``maximumResumeRewind``), keeps the goal. Short-lived
    /// retargets are expected while a timer restarted at a rewound position waits for the seek, or during a load.
    public func didSeek(to time: Double) {
        guard var run else { return }
        lastPosition = time
        guard case .chapterEnd(let segmentEnd, _) = run.goal else {
            if run.fadeStart != nil { run.fadeStart = time }
            self.run = run
            return
        }
        guard let timeline = control.timeline else {
            stopRun()
            return
        }
        let end = chapterEnd(at: time, keeping: segmentEnd) ?? timeline.duration
        if end != segmentEnd {
            run.goal = .chapterEnd(segmentEnd: end, offset: 0)
            run.wasCutShort = false
        }
        update(run, at: time)
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
            goal = .chapterEnd(segmentEnd: end, offset: 0)
        }
        endGrace()
        lastPosition = time
        lastTick = now()
        startTicking()
        update(Run(goal: goal, isAutomatic: isAutomatic), at: time)
        updateShakeDetection()
        return true
    }

    /// Stores `run` with what it has left at `time` (default: now): arms the chime above the lead time, tracks
    /// the fade and applies its volume.
    private func update(_ run: Run, at time: Double? = nil) {
        var run = run
        let time = time ?? control.currentTime
        let left = Self.remaining(of: run, at: time, rate: rate)
        if run.chime == .waiting, left > Self.chimeLeadTime { run.chime = .armed }
        trackFade(of: &run, left: left, at: time)
        self.run = run
        applyVolume(fadeVolume(left))
        publish(remaining: max(left, 0))
    }

    private func tick() {
        tickCount += 1
        guard var run else { return }
        let isPlaying = control.isPlaying
        let time = control.currentTime
        let tickTime = now()
        let interval = max(tickTime - lastTick, 0)
        lastTick = tickTime
        // A jump playback can't explain is a seek that wasn't reported (yet): retarget instead of expiring.
        if let lastPosition {
            let advance = time - lastPosition
            if advance < -Self.seekThreshold || advance > rate * interval + Self.seekThreshold {
                didSeek(to: time)
                guard let seeked = self.run else { return }
                run = seeked
            }
        }
        lastPosition = time
        // Capped, so a tick that ran late after a suspension doesn't count the time the app didn't play.
        if isPlaying { run.elapsed += min(interval, 2 * Self.seconds(tickInterval)) }
        let left = Self.remaining(of: run, at: time, rate: rate)
        // While paused only the end of the media expires a timer: a seek may not have landed yet.
        if left <= 0, isPlaying || time >= (control.timeline?.duration ?? 0) {
            self.run = run
            expire()
            return
        }
        if run.chime == .armed, left <= Self.chimeLeadTime {
            // Jumping well past the lead time (a subtract or seek) skips the chime instead of playing it late.
            if left <= Self.chimeLeadTime - 2 * Self.seconds(tickInterval) {
                run.chime = .played
            } else if isPlaying {
                run.chime = .played
                if options.playsAlmostDoneChime { feedback.playChime() }
            }
        }
        trackFade(of: &run, left: left, at: time)
        self.run = run
        applyVolume(fadeVolume(left))
        publish(remaining: max(left, 0))
        updateShakeDetection()
    }

    /// Notes where a duration run's fade began, to rewind there after it expires; time added above the fade
    /// forgets it (legacy iOS `AudioPlayer.startFadeOut` and the seek back after it, 33c73887). End-of-chapter
    /// runs don't rewind: playing again would stop at the same chapter end.
    private func trackFade(of run: inout Run, left: TimeInterval, at time: Double) {
        guard options.fadesOut, case .length = run.goal, left <= Self.fadeDuration else {
            run.fadeStart = nil
            return
        }
        if run.fadeStart == nil { run.fadeStart = time }
    }

    /// Pauses, then seeks back to where a duration run's fade began, and keeps the automatic rewind for that
    /// position.
    private func expire() {
        guard let run else { return }
        control.pause()
        if !run.wasCutShort { startGrace(for: run) }
        stopRun()
        let rewind = run.isAutomatic ? options.autoSleep.rewindOnExpiry : nil
        guard let fadeStart = run.fadeStart, fadeStart < control.currentTime else {
            pendingRewind = rewind.map { ($0, control.currentTime) }
            return
        }
        pendingRewind = nil
        Task { [weak self] in
            guard let self, let landed = await control.seek(to: fadeStart) else { return }
            didSeek(to: landed)
            pendingRewind = rewind.map { ($0, landed) }
        }
    }

    /// Plays after a grace-period reset, rewinding to `time` first; stops the run when the rewind doesn't land.
    private func resume(rewindingTo time: Double?) async {
        if let time {
            guard let landed = await control.seek(to: time) else {
                stopRun()
                return
            }
            didSeek(to: landed)
        }
        control.play()
        if options.playsResetFeedback { feedback.playResetFeedback() }
    }

    /// The pending rewind, consumed; nothing once playback moved away from where it was set.
    private func takeRewind() -> TimeInterval {
        defer { pendingRewind = nil }
        guard let pendingRewind, abs(control.currentTime - pendingRewind.at) < 1 else { return 0 }
        return pendingRewind.seconds
    }

    /// Ends the run (not its grace period), restoring the volume.
    private func stopRun() {
        run = nil
        tickTask?.cancel()
        tickTask = nil
        applyVolume(1)
        publish(remaining: nil)
        updateShakeDetection()
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
        graceEnd = now() + Self.gracePeriod
        let clock = clock
        let grace = Duration.seconds(Self.gracePeriod)
        graceTask = Self.schedule(on: clock, every: grace, repeats: false, owner: self) { $0.graceDidEnd() }
    }

    private func graceDidEnd() {
        endGrace()
        publish(remaining: remaining)
        updateShakeDetection()
    }

    private func endGrace() {
        expiredRun = nil
        graceEnd = nil
        graceTask?.cancel()
        graceTask = nil
    }

    /// The expired run, unless the grace period is over (the grace task may not have run yet after a suspension).
    private var restartableRun: Run? {
        guard let expiredRun, let graceEnd, now() < graceEnd else { return nil }
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
        case .chapterEnd(let segmentEnd, let offset): (segmentEnd + offset - time) / rate
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

    /// The chapter end for a seek to `time`. Keeps `segmentEnd` within its segment and up to
    /// ``maximumResumeRewind`` seconds into the one before it: a resume rewind after the timer restarted past a
    /// chapter's end must not pull the goal back to that end (Android never retargets on seeks).
    private func chapterEnd(at time: Double, keeping segmentEnd: Double) -> Double? {
        guard let timeline = control.timeline, let end = chapterEnd(at: time, skippingShortRemainder: false) else {
            return nil
        }
        let isJustBefore =
            end - time <= Self.maximumResumeRewind && Self.segmentEnd(in: timeline, at: end) == segmentEnd
        return end == segmentEnd || isJustBefore ? segmentEnd : end
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
        let isActive = (run != nil && control.isPlaying) || restartableRun != nil
        let sensitivity = isActive ? options.shakeSensitivity : nil
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

    /// Seconds elapsed on `clock` since the call.
    private nonisolated static func stopwatch<C: Clock<Duration>>(on clock: C) -> @Sendable () -> TimeInterval {
        let start = clock.now
        return { seconds(start.duration(to: clock.now)) }
    }

    private nonisolated static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
