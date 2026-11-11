import ABSCore
import ABSData
import ABSPlayback
import Foundation
import Observation

/// Which message the player shows for a playback failure. The view layer maps each case to a
/// localized string.
public enum PlayerErrorMessage: Sendable, Hashable {
    /// The path is metered and streaming needs the user's confirmation.
    case streamingNeedsConfirmation
    /// The path is metered and streaming on it is turned off.
    case streamingNotAllowed
    /// The server didn't open a playback session.
    case sessionStartFailed
    /// The media's stream couldn't be resolved.
    case streamUnavailable
    /// The media couldn't be loaded or stopped playing.
    case playbackFailed

    init(_ error: PlaybackCoordinatorError) {
        switch error {
        case .streamingNeedsConfirmation: self = .streamingNeedsConfirmation
        case .streamingNotAllowed: self = .streamingNotAllowed
        case .sessionStartFailed: self = .sessionStartFailed
        case .streamUnavailable: self = .streamUnavailable
        case .engine, .playback, .unexpected: self = .playbackFailed
        }
    }
}

/// State and commands for the mini player and the full player (port of
/// `components/app/AudioPlayer.vue`), shared by every window scene.
///
/// - **State.** Everything is derived from the playback seam and ``AppSettings`` when read, so it
///   follows them through Observation. Only scrubbing and the retained display text are stored.
/// - **Display text.** Title, author, chapter title and cover follow `NowPlayingBridge`: a closing
///   session, a restart or a failed load keep the last text for the same item.
/// - **Progress.** ``elapsed``, ``remaining`` and ``progress`` are relative to the current chapter
///   when ``AppSettings/chapterTrack`` is on and a chapter is playing, else to the whole item, in
///   media seconds; ``remainingAtRate`` is the wall-clock time left.
/// - **Scrubbing.** Between ``beginScrub()`` and ``endScrub()`` the times and progress show the
///   scrub position over the range fixed when it began, ignoring playback ticks; ``endScrub()``
///   seeks once, and only if the position moved. A change of item or session cancels the scrub.
/// - **Presentation.** Whether the full player or an inspector is shown is per scene, on `Router`
///   (ADR 0004), not here.
@MainActor
@Observable
public final class PlayerViewModel {
    @ObservationIgnored private let playback: any PlayerPlaybackControlling
    @ObservationIgnored private let settings: AppSettings
    /// The scrub in progress, if any.
    private var scrubState: Scrub?
    /// The last display text seen, so a dropped session keeps it. Updated whenever the display is
    /// read, and synchronously just before each item, session or record change, so it holds a
    /// session's text even if no view read it.
    @ObservationIgnored private var retainedDisplay: PlayerDisplayInfo?

    private struct Scrub {
        var key: MediaKey?
        var range: Span
        var time: Double
        /// Whether ``scrub(to:)`` moved it; an unmoved scrub (a tap) doesn't seek.
        var moved = false
    }

    /// The span the scrubber shows, with ``ABSPlayback/TimelineRange``'s clamping (whose
    /// initializer isn't public, and which an unloaded item has none of).
    private struct Span {
        var start: Double
        var end: Double

        init(start: Double, end: Double) {
            self.start = start
            self.end = max(end, start)
        }

        init(_ range: TimelineRange) {
            self.init(start: range.start, end: range.end)
        }

        var duration: Double { end - start }

        func elapsed(at time: Double) -> Double {
            min(max((time.isNaN ? start : time) - start, 0), duration)
        }

        func remaining(at time: Double) -> Double { duration - elapsed(at: time) }

        func fraction(at time: Double) -> Double { duration > 0 ? elapsed(at: time) / duration : 0 }

        func time(forElapsed elapsed: Double) -> Double {
            start + min(max(elapsed.isNaN ? 0 : elapsed, 0), duration)
        }
    }

    public init(playback: any PlayerPlaybackControlling, settings: AppSettings) {
        self.playback = playback
        self.settings = settings
        trackDisplay()
    }

    // MARK: Item

    /// Whether there is a current item, loaded or not (such as one restored at launch).
    public var hasSession: Bool { playback.phase != .idle }

    public var title: String { display?.title ?? "" }

    /// The book's author, or the podcast's title for an episode.
    public var author: String { display?.author ?? "" }

    /// The current chapter's title; `nil` without one. Before the media loads (or after its session
    /// drops), the chapter at the position in the last session's chapters, else the restored
    /// record's.
    public var chapterTitle: String? {
        guard playback.timeline != nil else { return display?.chapterTitle(at: playback.currentTime) }
        return PlayerDisplayInfo.nonEmpty(playback.chapter?.title)
    }

    /// The item's cover; `nil` when it has none.
    public var coverKey: ImageKey? { display?.coverKey }

    /// Which failure to show; `nil` when there is none. It can be set while ``hasSession`` is
    /// `false` (a play refused before any item was current), so the composition that starts playback
    /// must surface it too, not only the player bar.
    public var errorMessageKey: PlayerErrorMessage? { playback.error.map(PlayerErrorMessage.init) }

    // MARK: Transport

    public var isPlaying: Bool { playback.isPlaying }
    public var isBuffering: Bool { playback.isBuffering }
    /// Whether the play/pause button shows pause: while play is requested, including while starting
    /// or stalled.
    public var showsPause: Bool { playback.isPlaybackRequested }
    public var rate: Double { playback.rate }
    public var jumpForwardSeconds: Int { settings.jumpForwardTime }
    public var jumpBackwardSeconds: Int { settings.jumpBackwardsTime }
    /// Whether the scrubber shows the current chapter rather than the whole item.
    public var usesChapterTrack: Bool { settings.chapterTrack }

    /// Whether previous chapter does anything: media is loaded. Without chapters it restarts the
    /// item, as the legacy player did.
    public var hasPreviousChapter: Bool { playback.timeline != nil }

    /// Whether a chapter starts after the current position. Reads the playback time, so a view that
    /// reads it updates on every tick; keep it out of the mini player's body.
    public var hasNextChapter: Bool {
        guard let timeline = playback.timeline else { return false }
        return timeline.nextChapterStart(from: playback.currentTime) != nil
    }

    // MARK: Progress

    /// Seconds played in the shown range.
    public var elapsed: Double {
        let (range, time) = shownPosition
        return range.elapsed(at: time)
    }

    /// Seconds left in the shown range.
    public var remaining: Double {
        let (range, time) = shownPosition
        return range.remaining(at: time)
    }

    /// ``remaining`` in wall-clock seconds at the current rate (legacy `timeRemaining`); a
    /// non-finite or non-positive rate counts as `1`.
    public var remainingAtRate: Double {
        let rate = playback.rate
        return remaining / (rate.isFinite && rate > 0 ? rate : 1)
    }

    /// The fraction of the shown range played, `0...1`.
    public var progress: Double {
        let (range, time) = shownPosition
        return range.fraction(at: time)
    }

    // MARK: Commands

    /// Pauses while play is requested (also while starting or stalled), else resumes.
    public func togglePlayPause() async {
        if playback.isPlaybackRequested {
            playback.pause()
        } else {
            await playback.resume(rewindingBy: nil)
        }
    }

    public func jumpForward() async {
        await playback.jump(by: Double(settings.jumpForwardTime))
    }

    public func jumpBackward() async {
        await playback.jump(by: -Double(settings.jumpBackwardsTime))
    }

    /// Restarts the current chapter when more than
    /// ``ABSPlayback/PlaybackTimeline/previousChapterRestartThreshold`` seconds in, else goes to the
    /// previous one (legacy `jumpChapterStart`). Without chapters it restarts the item; without
    /// loaded media it does nothing.
    public func previousChapter() async {
        guard let timeline = playback.timeline else { return }
        await playback.seek(to: timeline.previousChapterStart(from: playback.currentTime))
    }

    /// Goes to the next chapter's start; does nothing in the last chapter or without chapters.
    public func nextChapter() async {
        guard let start = playback.timeline?.nextChapterStart(from: playback.currentTime) else { return }
        await playback.seek(to: start)
    }

    /// Starts scrubbing over the range shown now. Does nothing without an item or with an empty
    /// range (an unloaded item of unknown duration, or one still starting).
    public func beginScrub() {
        guard hasSession else { return }
        let (range, time) = shownPosition
        guard range.duration > 0 else { return }
        scrubState = Scrub(key: playback.mediaKey, range: range, time: range.time(forElapsed: range.elapsed(at: time)))
    }

    /// Moves the scrub position to `fraction` (`0...1`) of the shown range, beginning a scrub if
    /// none is in progress.
    public func scrub(to fraction: Double) {
        if activeScrub == nil { beginScrub() }
        guard var scrub = activeScrub else { return }
        let fraction = fraction.isNaN ? 0 : min(max(fraction, 0), 1)
        scrub.time = scrub.range.time(forElapsed: fraction * scrub.range.duration)
        scrub.moved = true
        scrubState = scrub
    }

    /// Ends scrubbing and seeks to the scrub position, once. A scrub that never moved, or that a
    /// change of item or session cancelled, ends without seeking: seeking an unloaded item would
    /// replace its resume position.
    public func endScrub() async {
        let scrub = activeScrub
        scrubState = nil
        guard let scrub, scrub.moved else { return }
        await playback.seek(to: scrub.time)
    }

    /// Sets and saves the playback rate.
    public func setRate(_ rate: Double) {
        playback.setRate(rate)
    }

    /// Switches the scrubber between the current chapter and the whole item; saved in settings.
    public func toggleChapterTrack() {
        settings.chapterTrack.toggle()
    }

    /// Stops playback and closes the item, as the user's close button.
    public func close() {
        scrubState = nil
        playback.stop(reason: .user)
    }

    // MARK: Private

    /// The scrub, while it is for the current item.
    private var activeScrub: Scrub? {
        guard let scrub = scrubState, scrub.key == playback.mediaKey else { return nil }
        return scrub
    }

    /// The range the scrubber shows and the time in it: the scrub's while scrubbing, which reads
    /// no playback time, so ticks don't invalidate it.
    private var shownPosition: (range: Span, time: Double) {
        if let scrub = activeScrub { return (scrub.range, scrub.time) }
        let time = playback.currentTime
        if settings.chapterTrack, let range = playback.chapterRange { return (Span(range), time) }
        let duration = playback.duration
        return (Span(start: 0, end: duration.isFinite ? duration : 0), time)
    }

    private var display: PlayerDisplayInfo? {
        let info = PlayerDisplayInfo.resolve(
            key: playback.mediaKey, session: playback.session, restoredRecord: playback.restoredRecord,
            retaining: retainedDisplay)
        retainedDisplay = info
        return info
    }

    /// Runs just before every item, session or record change (Observation calls `onChange` on
    /// `willSet`, while the old values are still readable): captures the outgoing display text, so it
    /// is kept even when no view read it, cancels any scrub, and observes again.
    private func trackDisplay() {
        withObservationTracking {
            _ = display
        } onChange: { [weak self] in
            // Safe: every conformer is `@MainActor` (the protocol is), so its properties change, and
            // `onChange` runs, on the main actor. This keeps the capture synchronous, before the change.
            MainActor.assumeIsolated { self?.displayWillChange() }
        }
    }

    private func displayWillChange() {
        scrubState = nil
        trackDisplay()
    }
}
