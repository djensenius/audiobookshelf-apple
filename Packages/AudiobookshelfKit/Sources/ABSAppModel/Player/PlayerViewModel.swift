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
/// - **Scrubbing.** Between ``beginScrub(owner:)`` and ``endScrub(owner:)`` the times and progress
///   show the scrub position over the range fixed when it began, ignoring playback ticks;
///   ``endScrub(owner:)`` seeks once, and only if the position moved. A view splits it into
///   ``finishScrub(owner:)``, synchronously when its gesture ends, and ``commitScrub(_:)`` in a
///   task, so its disappearing in between can't cancel the seek. A change of item cancels the
///   scrub, and the rest of that gesture is ignored until its ``endScrub(owner:)`` or a new
///   ``beginScrub(owner:)``; the same item loading (a new session, the restored record cleared)
///   doesn't cancel it. No scrub begins while an item is starting, before its resume position is
///   known.
/// - **Scrub ownership.** Every window shares this model but there is one scrub, so each scrubber
///   passes its own ``ScrubOwner``. While one owner's scrub is in progress, other owners can't
///   begin, move, end or cancel a scrub: their calls are ignored (the first drag wins), so two
///   windows dragging at once can't move or commit each other's position. A scrubber that goes
///   away must ``cancelScrub(owner:)``, or its scrub would block the others.
/// - **Ineligible gestures.** A gesture that was rejected (another owner was scrubbing, or no
///   scrub could start: no item, an item starting, an empty range) or cancelled (an item change or
///   ``close()``) stays ineligible: its later ``scrub(to:owner:)``
///   calls are ignored, even once nothing else is scrubbing, so it never scrubs, or on release
///   seeks, an item it didn't start on. Each owner's gesture is tracked separately, so one
///   window's new gesture doesn't make another's eligible again. An owner becomes eligible only
///   when its gesture ends (``endScrub(owner:)``), its view goes away (``cancelScrub(owner:)``) or
///   it explicitly begins a fresh gesture (``beginScrub(owner:)``). A ``scrub(to:owner:)`` never
///   counts as a fresh gesture: it may continue the drag that was rejected or cancelled.
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
    /// The owners whose current gesture was rejected or cancelled: their further
    /// ``scrub(to:owner:)`` calls, from the same gesture, must not begin a scrub.
    @ObservationIgnored private var ineligibleScrubOwners: Set<ScrubOwner> = []
    /// Counts item changes and closes, so a finished scrub can tell that its item went away even
    /// if the same item is back by the time it seeks.
    @ObservationIgnored private var itemGeneration = 0

    /// Identifies one scrubber (one view's gesture), so scrubbers in different windows can't move
    /// or end each other's scrub. Make one per scrubber and keep it for the view's lifetime.
    public struct ScrubOwner: Hashable, Sendable {
        private let id = UUID()

        public init() {}
    }

    /// The seek a finished scrub needs; see ``finishScrub(owner:)``.
    public struct ScrubSeek: Sendable, Hashable {
        fileprivate let key: MediaKey?
        fileprivate let generation: Int
        /// The media time to seek to.
        public let time: Double
    }

    private struct Scrub {
        var owner: ScrubOwner
        var key: MediaKey?
        var range: Span
        var time: Double
        /// Whether ``scrub(to:owner:)`` moved it; an unmoved scrub (a tap) doesn't seek.
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
        trackItem()
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

    /// Whether the current item is a podcast episode, so its cover is square; podcasts play only
    /// episodes, and books have no episode ID. `false` without an item.
    public var isPodcastEpisode: Bool { playback.mediaKey?.episodeId != nil }

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

    /// Starts a fresh gesture for `owner`, making it eligible again, and scrubs over the range shown
    /// now, replacing its own scrub if any. The gesture is rejected, and stays ineligible until it
    /// ends, while another owner is scrubbing, without an item, while the item is starting (a seek
    /// would replace the resume position still being resolved), or with an empty range (an
    /// unloaded item of unknown duration).
    public func beginScrub(owner: ScrubOwner) {
        ineligibleScrubOwners.remove(owner)
        startScrub(owner: owner)
    }

    /// Starts `owner`'s scrub, or marks its gesture ineligible if it can't; see
    /// ``beginScrub(owner:)``.
    private func startScrub(owner: ScrubOwner) {
        let othersScrub = activeScrub.map { $0.owner != owner } ?? false
        guard !othersScrub, hasSession, playback.phase != .starting else {
            ineligibleScrubOwners.insert(owner)
            return
        }
        let (range, time) = shownPosition
        guard range.duration > 0 else {
            ineligibleScrubOwners.insert(owner)
            return
        }
        scrubState = Scrub(
            owner: owner, key: playback.mediaKey, range: range,
            time: range.time(forElapsed: range.elapsed(at: time)))
    }

    /// Moves `owner`'s scrub position to `fraction` (`0...1`) of the shown range, beginning a scrub
    /// if none is in progress, unless this gesture is ineligible: another owner was scrubbing, no
    /// scrub could start, or an item change cancelled its scrub. Rejecting a move makes the gesture ineligible.
    ///
    /// A fraction within a tiny tolerance (1e-9) of the shown ``progress`` isn't a move, so
    /// passing back the value read (a thumb that didn't move) never seeks. Fractions are compared,
    /// not seconds: converting a fraction back to seconds doesn't round-trip exactly.
    public func scrub(to fraction: Double, owner: ScrubOwner) {
        guard !ineligibleScrubOwners.contains(owner) else { return }
        if activeScrub == nil { startScrub(owner: owner) }
        guard var scrub = activeScrub else { return }
        guard scrub.owner == owner else {
            ineligibleScrubOwners.insert(owner)
            return
        }
        let fraction = fraction.isNaN ? 0 : min(max(fraction, 0), 1)
        guard abs(fraction - scrub.range.fraction(at: scrub.time)) > Self.scrubFractionTolerance else { return }
        scrub.time = scrub.range.time(forElapsed: fraction * scrub.range.duration)
        scrub.moved = true
        scrubState = scrub
    }

    /// Ends `owner`'s scrub and seeks to its position, once: ``finishScrub(owner:)`` then
    /// ``commitScrub(_:)``.
    public func endScrub(owner: ScrubOwner) async {
        guard let seek = finishScrub(owner: owner) else { return }
        await commitScrub(seek)
    }

    /// Ends `owner`'s scrub now and returns the seek it needs, for ``commitScrub(_:)``.
    ///
    /// A view whose gesture ends calls this synchronously, before scheduling the seek, so a
    /// ``cancelScrub(owner:)`` from its disappearing in between finds nothing to cancel and the
    /// seek isn't lost. A scrub that never moved, or that a change of item cancelled, returns `nil`:
    /// seeking an unloaded item would replace its resume position. Does nothing to another owner's
    /// scrub. Makes `owner` eligible again.
    public func finishScrub(owner: ScrubOwner) -> ScrubSeek? {
        ineligibleScrubOwners.remove(owner)
        let scrub = activeScrub
        if scrubState?.owner == owner { scrubState = nil }
        guard let scrub, scrub.owner == owner, scrub.moved else { return nil }
        return ScrubSeek(key: scrub.key, generation: itemGeneration, time: scrub.time)
    }

    /// Seeks to a finished scrub's position, unless the item changed or closed since it finished,
    /// even if the same item has come back: seeking it would replace its resolved start position.
    public func commitScrub(_ seek: ScrubSeek) async {
        guard seek.generation == itemGeneration, seek.key == playback.mediaKey else { return }
        await playback.seek(to: seek.time)
    }

    /// Drops `owner`'s scrub without seeking, for a scrubber that goes away mid-drag. Does nothing
    /// to another owner's scrub. Makes `owner` eligible again.
    public func cancelScrub(owner: ScrubOwner) {
        ineligibleScrubOwners.remove(owner)
        if scrubState?.owner == owner { scrubState = nil }
    }

    /// Sets and saves the playback rate.
    public func setRate(_ rate: Double) {
        playback.setRate(rate)
    }

    /// Switches the scrubber between the current chapter and the whole item; saved in settings.
    public func toggleChapterTrack() {
        settings.chapterTrack.toggle()
    }

    /// Stops playback and closes the item, as the user's close button. Cancels any scrub like an
    /// item change (the item-change observer won't see one cleared here), so the rest of a drag, in
    /// any window, doesn't scrub an item loaded before it ends.
    public func close() {
        itemGeneration += 1
        if let scrub = scrubState {
            scrubState = nil
            ineligibleScrubOwners.insert(scrub.owner)
        }
        playback.stop(reason: .user)
    }

    // MARK: Private

    /// Fractions this close are the same scrub position: rounding noise, under a millisecond for
    /// any range shorter than about 277 hours.
    private static let scrubFractionTolerance = 1e-9

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
    /// is kept even when no view read it, and observes again.
    private func trackDisplay() {
        withObservationTracking {
            _ = display
        } onChange: { [weak self] in
            // Safe: every conformer is `@MainActor` (the protocol is), so its properties change, and
            // `onChange` runs, on the main actor. This keeps the capture synchronous, before the change.
            MainActor.assumeIsolated { self?.trackDisplay() }
        }
    }

    /// Cancels any scrub whenever the item changes. Closing always passes through no item, so even
    /// the same item coming back starts without the old scrub. The coordinator doesn't set the key
    /// when the same item restarts, so a scrub survives its loading.
    private func trackItem() {
        withObservationTracking {
            _ = playback.mediaKey
        } onChange: { [weak self] in
            // Safe for the same reason as in `trackDisplay()`.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.itemGeneration += 1
                if let scrub = self.scrubState {
                    self.scrubState = nil
                    self.ineligibleScrubOwners.insert(scrub.owner)
                }
                self.trackItem()
            }
        }
    }
}
