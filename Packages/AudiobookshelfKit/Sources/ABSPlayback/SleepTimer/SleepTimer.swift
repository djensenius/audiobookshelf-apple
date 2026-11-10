import ABSCore
import Foundation
import Observation

/// The sleep timer: pauses playback after a duration or at the end of the chapter.
///
/// - A duration counts down only while audio plays (legacy iOS); an end-of-chapter timer pauses when playback
///   reaches the chapter's end, in wall-clock seconds at the current rate, less gaps between tracks.
/// - The volume fades out over the last ``fadeDuration`` seconds and is restored after the pause. A duration
///   timer then seeks back to where the fade began (legacy iOS `AudioPlayer.startFadeOut`).
/// - The chime plays once per run, ``chimeLeadTime`` seconds before the end. It waits while less is left (after a
///   short start, until an add or a slower rate lifts it), and a jump past that moment skips it.
/// - For ``gracePeriod`` seconds after the timer pauses playback, ``reset()`` or playing the same item restarts it.
/// - ``reset()`` restarts a running timer while audio plays. The `shakeDetector` calls it for shake to reset, only
///   while a reset can do something. Once paused in the background iOS likely suspends the app, so a shake during
///   the grace period probably only works in the foreground (to be checked on a device).
/// - An automatic timer starts when playback starts inside the ``AutoSleepPolicy`` window.
///
/// The playback coordinator (#52) conforms to ``SleepTimerPlaybackControl`` and calls:
/// - ``itemDidChange(_:)`` when another item loads;
/// - ``playbackWillStart(at:)`` before every play, before its resume seek (AutoRewind), adding what it returns to
///   that rewind;
/// - ``playbackDidPause()`` whenever anything but the timer pauses playback;
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
    /// The shortest tick interval: a zero or negative one would tick without pause on the main actor and never
    /// count a duration down.
    static let minimumTickInterval: Duration = .milliseconds(100)
    /// An end-of-chapter timer started with less than this many media seconds of the chapter left waits for the next
    /// one (Android `getChapterEndTime`, at any rate; legacy iOS had no cutoff).
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
    /// Whether the timer recently paused playback and a reset or play would restart it.
    public private(set) var canRestart = false
    public var isRunning: Bool { mode != nil }
    /// Takes effect at the next tick; changes to the shake sensitivity apply immediately.
    public var options: SleepTimerOptions {
        didSet { updateShakeDetection() }
    }

    private enum Goal {
        case length(TimeInterval)
        /// The end of the chapter (or gap, or track), moved by added and subtracted listening time.
        case chapterEnd(segmentEnd: Double, offset: Double)

        var isChapterEnd: Bool { if case .chapterEnd = self { true } else { false } }
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
        /// The item a chapter goal belongs to; once another loads, a seek retargets without keeping the goal.
        var item: String?
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
    @ObservationIgnored private let feedback: (any SleepTimerFeedback)?
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
    /// Changes when a run begins or stops, or playback plays or pauses, so a reset's resume can tell it was overtaken.
    @ObservationIgnored private var runID = 0
    /// The position and ``now`` at the last tick, seek or start, to spot seeks nobody reported.
    @ObservationIgnored private var lastPosition: Double?
    @ObservationIgnored private var lastTick: TimeInterval = 0
    /// Where playback was when a run began at a rewound position; ticks ignore it until the rewind's seek lands.
    @ObservationIgnored private var stalePosition: Double?
    @ObservationIgnored private var autoSleepSuppressedUntil: Date?
    @ObservationIgnored private var appliedVolume: Float = 1
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var detectingSensitivity: ShakeSensitivity?
    /// Ticks so far, for tests.
    @ObservationIgnored private(set) var tickCount = 0
    var isTicking: Bool { tickTask != nil }

    /// - Parameters:
    ///   - feedback: Pass ``SystemSleepTimerFeedback`` for the chime and the reset feedback; `nil` plays nothing.
    ///   - shakeDetector: Pass ``ShakeDetector`` on iOS; `nil` disables shake to reset.
    ///   - tickInterval: How often the countdown, fade and chime update; at least ``minimumTickInterval``.
    public init(
        control: any SleepTimerPlaybackControl,
        feedback: (any SleepTimerFeedback)? = nil,
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
        self.tickInterval = max(tickInterval, Self.minimumTickInterval)
        now = Self.stopwatch(on: clock)
    }

    isolated deinit {
        tickTask?.cancel()
        graceTask?.cancel()
        if detectingSensitivity != nil { shakeDetector?.stop() }
        // Torn down mid-fade, the volume would otherwise stay attenuated.
        if appliedVolume != 1 { control.setVolume(1) }
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

    /// Adds `seconds` of listening time. For end of chapter, the end moves past `seconds` of media at the current
    /// rate, skipping gaps between tracks, up to the end of the media. Unlike Android, a duration isn't capped at
    /// the media left: it only counts down while audio plays.
    public func add(_ seconds: TimeInterval) {
        guard var run, seconds.isFinite, seconds > 0 else { return }
        switch run.goal {
        case .length(let length):
            run.goal = .length(length + seconds)
        case .chapterEnd(let segmentEnd, let offset):
            let limit = max(control.timeline?.duration ?? .infinity, segmentEnd + offset)
            let end = Self.position(in: control.timeline, from: segmentEnd + offset, playing: seconds * rate)
            run.goal = .chapterEnd(segmentEnd: segmentEnd, offset: min(end, limit) - segmentEnd)
        }
        run.wasCutShort = false
        // Past what a Double holds, the timer would never expire.
        guard remaining(of: run).isFinite else { return }
        update(run)
    }

    /// Removes `seconds` of listening time, leaving at least ``minimumRemaining``. For end of chapter, the end moves
    /// to where that much media plays from now at the current rate, skipping gaps between tracks.
    public func subtract(_ seconds: TimeInterval) {
        guard var run, seconds.isFinite, seconds > 0 else { return }
        let left = remaining(of: run)
        let newLeft = min(left, max(left - seconds, Self.minimumRemaining))
        if left - seconds <= Self.minimumRemaining { run.wasCutShort = true }
        switch run.goal {
        case .length(let length): run.goal = .length(length - (left - newLeft))
        case .chapterEnd(let segmentEnd, _) where newLeft < left:
            let end = Self.position(in: control.timeline, from: control.currentTime, playing: newLeft * rate)
            run.goal = .chapterEnd(segmentEnd: segmentEnd, offset: end - segmentEnd)
        case .chapterEnd: break
        }
        update(run)
    }

    /// Resets the timer, for a gesture such as shake to reset. A running timer restarts while audio plays (a
    /// duration only after ``resetGuard`` seconds); during the grace period the expired timer restarts and playback
    /// resumes after the pending rewind, with the reset feedback once it plays. A cancel, a start, a play, a pause or
    /// another item before that rewind lands wins: nothing resumes (only a cancel stops the restarted timer). If the
    /// rewind fails, or a seek moved playback or is moving it, the grace period and the rewind come back. Returns
    /// whether it reset.
    @discardableResult
    public func reset() -> Bool {
        if let run {
            if case .length = run.goal, run.elapsed <= Self.resetGuard { return false }
            guard control.isPlaying, begin(run.mode, isAutomatic: run.isAutomatic, at: control.currentTime) else {
                return false
            }
            if options.playsResetFeedback { feedback?.playResetFeedback() }
            return true
        }
        guard let expiredRun = restartableRun, let graceEnd else { return false }
        let rewind = pendingRewind
        let time = time(rewoundBy: takeRewind())
        guard begin(expiredRun.mode, isAutomatic: expiredRun.isAutomatic, at: time) else {
            pendingRewind = rewind
            return false
        }
        let target = time < control.currentTime ? time : nil
        let id = runID, item = itemID, position = control.currentTime
        Task { [weak self] in
            await self?.resume(rewindingTo: target, from: position, runID: id, item: item) {
                $0.startGrace(for: expiredRun, until: graceEnd)
                $0.pendingRewind = rewind
            }
        }
        return true
    }

    /// Call before playback starts, and before the resume seek. Restarts a timer that expired during the grace
    /// period, or starts the automatic timer inside its window. Returns the seconds to rewind before playing,
    /// which are consumed: the automatic rewind, if playback is still where the automatic timer paused it.
    public func playbackWillStart(at date: Date = .now) -> TimeInterval {
        runID += 1
        let rewind = takeRewind()
        guard run == nil else { return rewind }
        let time = time(rewoundBy: rewind)
        if let expiredRun = restartableRun {
            if begin(expiredRun.mode, isAutomatic: expiredRun.isAutomatic, at: time), options.playsResetFeedback {
                feedback?.playResetFeedback()
            }
        } else if shouldStartAutomatically(at: date) {
            begin(options.autoSleep.mode, isAutomatic: true, at: time)
        }
        return rewind
    }

    /// Call when anything but the timer pauses playback (the user, an interruption). Only the timer's own pause is
    /// undone: the grace period ends, and a reset whose rewind is still in flight doesn't resume.
    public func playbackDidPause() {
        runID += 1
        endGrace()
        publish(remaining: remaining)
        updateShakeDetection()
    }

    /// Call when another item loads (`nil` when none): an expired timer restarts, and its rewind applies, only on
    /// the item it paused (Android `handleMediaPlayEvent` compares sessions). A running timer keeps running; an
    /// end-of-chapter one retargets at the ``didSeek(to:)`` for the new item's load. For a podcast, pass an ID
    /// combining the item and the episode.
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
    /// stops. A seek within the chapter or its added time, or just before it (``maximumResumeRewind``), keeps the
    /// goal, unless it passed what a subtraction left, or it's another item's. Short-lived retargets are expected
    /// while a timer restarted at a rewound position waits for the seek, or during a load.
    public func didSeek(to time: Double) {
        guard var run else { return }
        lastPosition = time
        stalePosition = nil
        guard case .chapterEnd(let segmentEnd, let offset) = run.goal else {
            if run.fadeStart != nil { run.fadeStart = time }
            self.run = run
            return
        }
        guard let timeline = control.timeline else {
            stopRun()
            return
        }
        let isSameItem = run.item == itemID
        let end =
            (isSameItem
                ? chapterEnd(at: time, keeping: segmentEnd, offset: offset)
                : chapterEnd(at: time, skippingShortRemainder: false)) ?? timeline.duration
        if !isSameItem || end != segmentEnd || segmentEnd + offset <= time {
            run.goal = .chapterEnd(segmentEnd: end, offset: 0)
            run.wasCutShort = false
            run.item = itemID
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
        runID += 1
        lastPosition = time
        stalePosition = time == control.currentTime ? nil : control.currentTime
        lastTick = now()
        startTicking()
        update(Run(goal: goal, isAutomatic: isAutomatic, item: itemID), at: time)
        updateShakeDetection()
        return true
    }

    /// Stores `run` with what it has left at `time` (default: now): arms the chime above the lead time, skips it
    /// when a jump (a subtract or seek) lands below it, tracks the fade and applies its volume.
    private func update(_ run: Run, at time: Double? = nil) {
        var run = run
        let time = time ?? control.currentTime
        let left = remaining(of: run, at: time)
        if run.chime == .waiting, left > Self.chimeLeadTime {
            run.chime = .armed
        } else if run.chime == .armed, left < Self.chimeLeadTime {
            run.chime = .played
        }
        trackFade(of: &run, left: left, at: time)
        self.run = run
        applyVolume(fadeVolume(left))
        publish(remaining: max(left, 0))
    }

    private func tick() {
        tickCount += 1
        guard var run else { return }
        let isPlaying = control.isPlaying
        var time = control.currentTime
        // Until a rewound start's seek lands (at the end of the media, say), count from the rewound position.
        if time != stalePosition { stalePosition = nil } else if let lastPosition { time = lastPosition }
        let tickTime = now()
        let interval = max(tickTime - lastTick, 0)
        lastTick = tickTime
        // A jump playback can't explain is a seek that wasn't reported (yet): retarget instead of expiring.
        if let lastPosition {
            let advance = Self.played(in: control.timeline, from: lastPosition, to: time)
            if advance < -Self.seekThreshold || advance > rate * interval + Self.seekThreshold {
                didSeek(to: time)
                guard let seeked = self.run else { return }
                run = seeked
            }
        }
        lastPosition = time
        // Capped, so a tick that ran late after a suspension doesn't count the time the app didn't play.
        if isPlaying { run.elapsed += min(interval, 2 * Self.seconds(tickInterval)) }
        let left = remaining(of: run, at: time)
        // While paused only the end of the media expires a timer: a seek may not have landed yet. A chapter timer
        // waits for a seek in flight, whose landing decides if it reached its goal; a duration's time is up anyway.
        if left <= 0, isPlaying || time >= (control.timeline?.duration ?? 0),
            !(run.goal.isChapterEnd && control.hasPendingSeek)
        {
            self.run = run
            expire()
            return
        }
        // A slower rate can lift a chapter's time left above the lead time.
        if run.chime == .waiting, left > Self.chimeLeadTime { run.chime = .armed }
        if run.chime == .armed, left <= Self.chimeLeadTime {
            // Jumping well past the lead time (a subtract or seek) skips the chime instead of playing it late.
            if left <= Self.chimeLeadTime - 2 * Self.seconds(tickInterval) {
                run.chime = .played
            } else if isPlaying {
                run.chime = .played
                if options.playsAlmostDoneChime { feedback?.playChime() }
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

    /// Pauses, then seeks back to where a duration run's fade began, and keeps the automatic rewind for where
    /// playback ends up.
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
        // A play or reset during the seek finds playback elsewhere and drops the rewind; a manual start keeps it. A
        // failed seek leaves it where playback paused, so a seek that superseded it drops it too.
        pendingRewind = rewind.map { ($0, fadeStart) }
        let item = itemID, pausedAt = control.currentTime
        Task { [weak self, control] in
            // Another item, or a seek that landed or is in flight before this task ran, wins.
            guard self?.isCurrent(item) == true, Self.isStill(control, at: pausedAt) else { return }
            let landed = await control.seek(to: fadeStart)
            guard let self, isCurrent(item) else { return }
            pendingRewind?.at = landed ?? pausedAt
            if let landed { didSeek(to: landed) }
        }
    }

    /// Plays after a grace-period reset, rewinding from `position` to `time` first, unless the run or the item
    /// changed, or playback played or paused, before or during the seek. When a seek moved playback from `position`
    /// or is moving it (with or without a rewind), or the rewind doesn't land, `undo` reopens the grace period and the
    /// run stops.
    private func resume(
        rewindingTo time: Double?, from position: Double, runID id: Int, item: String?, undo: (SleepTimer) -> Void
    ) async {
        guard isCurrent(item, runID: id) else { return }
        var landed = Self.isStill(control, at: position) ? control.currentTime : nil
        if let time, landed != nil { landed = await control.seek(to: time) }
        guard isCurrent(item, runID: id) else { return }
        guard let landed else {
            undo(self)
            stopRun()
            return
        }
        if time != nil { didSeek(to: landed) }
        control.play()
        if options.playsResetFeedback { feedback?.playResetFeedback() }
    }

    /// Whether work begun on `item`, and during run `id` if given, still applies. Checked before and after a seek,
    /// so another item loading, a cancel or start, or a play or pause, before it or during it wins.
    private func isCurrent(_ item: String?, runID id: Int? = nil) -> Bool {
        itemID == item && (id == nil || id == runID)
    }

    /// The pending rewind, consumed; nothing once playback moved away from where it was set, or a seek is moving it.
    private func takeRewind() -> TimeInterval {
        defer { pendingRewind = nil }
        guard let pendingRewind, Self.isStill(control, at: pendingRewind.at) else { return 0 }
        return pendingRewind.seconds
    }

    /// Whether playback is still at `position`, give or take a reporting error, with no seek or load in flight.
    private static func isStill(_ control: any SleepTimerPlaybackControl, at position: Double) -> Bool {
        !control.hasPendingSeek && abs(control.currentTime - position) < 1
    }

    /// Ends the run (not its grace period), restoring the volume.
    private func stopRun() {
        if run != nil { runID += 1 }
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

    /// Starts the grace period for `run`, or reopens it until `end`.
    private func startGrace(for run: Run, until end: TimeInterval? = nil) {
        endGrace()
        expiredRun = run
        let start = now()
        graceEnd = end ?? start + Self.gracePeriod
        let clock = clock
        let grace = Duration.seconds(end.map { max($0 - start, 0) } ?? Self.gracePeriod)
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

    /// What `run` has left at `time` (default: now). For end of chapter, the media seconds that play before its end,
    /// less gaps between tracks, at the current rate; zero or less once reached.
    private func remaining(of run: Run, at time: Double? = nil) -> TimeInterval {
        switch run.goal {
        case .length(let length): length - run.elapsed
        case .chapterEnd(let segmentEnd, let offset):
            Self.played(in: control.timeline, from: time ?? control.currentTime, to: segmentEnd + offset) / rate
        }
    }

    private func time(rewoundBy seconds: TimeInterval) -> Double {
        control.timeline?.jumpBackward(from: control.currentTime, by: seconds) ?? control.currentTime
    }

    /// Media seconds that play moving forward from `start` to `end`, less the gaps between tracks, so playback
    /// naturally crossing a gap isn't a seek. Moving back, the plain distance.
    private static func played(in timeline: PlaybackTimeline?, from start: Double, to end: Double) -> Double {
        guard let timeline, end > start else { return end - start }
        return timeline.tracks.reduce(0) { $0 + max(min($1.playbackEnd, end) - max($1.start, start), 0) }
    }

    /// Where playback is once `amount` media seconds play from `start`, skipping the gaps between tracks: the
    /// inverse of `played`. Past the last track, the plain distance.
    private static func position(in timeline: PlaybackTimeline?, from start: Double, playing amount: Double) -> Double {
        var position = start, left = amount
        for track in timeline?.tracks ?? [] where track.playbackEnd > position {
            let from = max(track.start, position)
            if left <= track.playbackEnd - from { return from + left }
            left -= track.playbackEnd - from
            position = track.playbackEnd
        }
        return position + left
    }

    /// The end of the chapter playing at `time` (or of the gap before the next chapter; of the track without
    /// chapters). When starting with less than ``minimumChapterRemaining`` seconds left, the end of the next one
    /// (Android `getChapterEndTime`).
    private func chapterEnd(at time: Double, skippingShortRemainder: Bool) -> Double? {
        guard let timeline = control.timeline, let end = Self.segmentEnd(in: timeline, at: time), end > time else {
            return nil
        }
        if skippingShortRemainder, end - time < Self.minimumChapterRemaining,
            let next = Self.segmentEnd(in: timeline, at: end), next > end
        {
            return next
        }
        return end
    }

    /// The chapter end for a seek to `time`. Keeps `segmentEnd` within its segment, within time added past it, and
    /// up to ``maximumResumeRewind`` seconds into the segment before it: a resume rewind after the timer restarted
    /// past a chapter's end must not pull the goal back to that end (Android never retargets on seeks).
    private func chapterEnd(at time: Double, keeping segmentEnd: Double, offset: Double) -> Double? {
        guard let timeline = control.timeline, let end = chapterEnd(at: time, skippingShortRemainder: false) else {
            return nil
        }
        let isJustBefore =
            end - time <= Self.maximumResumeRewind && Self.segmentEnd(in: timeline, at: end) == segmentEnd
        let isInAddedTime = segmentEnd <= time && time < segmentEnd + offset
        return end == segmentEnd || isJustBefore || isInAddedTime ? segmentEnd : end
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
