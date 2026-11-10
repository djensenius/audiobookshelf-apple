import ABSCore
import ABSData
import Foundation

/// What the system Now Playing surfaces (Lock Screen, Control Center, AirPods, Mac media keys,
/// CarPlay) should show, as plain values. The player builds one from its own state and hands it to
/// ``NowPlayingController/update(_:)``; `nil` means nothing is playing.
///
/// All times are global seconds from the start of the media. The controller derives chapter-relative
/// values itself in chapter-track mode (``NowPlayingSettings/chapterTrack``).
public struct NowPlayingState: Sendable, Equatable {
    /// The item: a book, or a podcast episode when `key.episodeId` is set.
    public var key: MediaKey
    /// Book title, or episode title for a podcast episode.
    public var title: String
    /// Author for a book, show name for a podcast episode.
    public var author: String
    /// Books only.
    public var narrator: String?
    /// Podcast episodes only.
    public var releaseDate: Date?
    /// The chapter playing now, or `nil` without chapters or in a gap between chapters.
    public var chapter: Chapter?
    public var duration: Double
    public var elapsed: Double
    /// The current playback rate, also while paused (the rate playback resumes at).
    public var rate: Double
    public var isPlaying: Bool
    /// Passed to the injected ``NowPlayingArtworkProvider``; `nil` when the item has no cover.
    /// Any stable string works (for example the cover's `ImageKey` description); changing it reloads
    /// the artwork.
    public var artworkKey: String?

    public struct Chapter: Sendable, Equatable {
        public var title: String
        /// 0-based index into the chapters counted by ``count`` (`PlaybackTimeline.chapters`).
        public var index: Int
        public var count: Int
        /// The chapter's span in global time.
        public var range: TimelineRange

        public init(title: String, index: Int, count: Int, range: TimelineRange) {
            self.title = title
            self.index = index
            self.count = count
            self.range = range
        }
    }

    public init(
        key: MediaKey, title: String, author: String, narrator: String? = nil, releaseDate: Date? = nil,
        chapter: Chapter? = nil, duration: Double, elapsed: Double, rate: Double, isPlaying: Bool,
        artworkKey: String? = nil
    ) {
        self.key = key
        self.title = title
        self.author = author
        self.narrator = narrator
        self.releaseDate = releaseDate
        self.chapter = chapter
        self.duration = duration
        self.elapsed = elapsed
        self.rate = rate
        self.isPlaying = isPlaying
        self.artworkKey = artworkKey
    }

    public var isPodcastEpisode: Bool { key.episodeId != nil }
}

/// The user settings Now Playing depends on.
public struct NowPlayingSettings: Sendable, Equatable {
    /// Seconds; also used by the remote next-track command (ADR 0006).
    public var jumpForwardTime: Double
    /// Seconds; also used by the remote previous-track command (ADR 0006).
    public var jumpBackwardsTime: Double
    /// Offer the seek (scrubber) command only when on.
    public var allowSeekingOnMediaControls: Bool
    /// Show the current chapter as the title, with chapter-relative duration and elapsed time.
    public var chapterTrack: Bool
    /// Rates offered by the system rate control.
    public var supportedRates: [Double]

    /// The legacy app's list (`AudioPlayer.setupRemoteTransportControls`).
    public static let defaultSupportedRates: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2]

    public init(
        jumpForwardTime: Double = Double(AppSettings.Default.jumpForwardTime),
        jumpBackwardsTime: Double = Double(AppSettings.Default.jumpBackwardsTime),
        allowSeekingOnMediaControls: Bool = AppSettings.Default.allowSeekingOnMediaControls,
        chapterTrack: Bool = AppSettings.Default.chapterTrack,
        supportedRates: [Double] = Self.defaultSupportedRates
    ) {
        self.jumpForwardTime = jumpForwardTime
        self.jumpBackwardsTime = jumpBackwardsTime
        self.allowSeekingOnMediaControls = allowSeekingOnMediaControls
        self.chapterTrack = chapterTrack
        self.supportedRates = supportedRates
    }

    /// Reads the current values. Reading inside `withObservationTracking` (or `Observations`) tracks
    /// exactly these settings, so the integration can reassign ``NowPlayingController/settings``
    /// whenever the user changes one.
    @MainActor
    public init(_ settings: AppSettings) {
        self.init(
            jumpForwardTime: Double(settings.jumpForwardTime),
            jumpBackwardsTime: Double(settings.jumpBackwardsTime),
            allowSeekingOnMediaControls: settings.allowSeekingOnMediaControls,
            chapterTrack: settings.chapterTrack
        )
    }
}

/// The player that remote commands act on: `PlaybackCoordinator` (or an adapter it owns) once Now
/// Playing is wired up. Times are global seconds.
@MainActor
public protocol NowPlayingCommandHandling: AnyObject {
    func play() async
    func pause() async
    func togglePlayPause() async
    func skipForward(by seconds: Double) async
    func skipBackward(by seconds: Double) async
    func seek(to time: Double) async
    func setRate(_ rate: Double) async
}

/// Loads cover image data (JPEG, PNG, HEIC…) for ``NowPlayingState/artworkKey``; `nil` when there is
/// none. Runs off the main actor and is cancelled when the item or artwork key changes.
public typealias NowPlayingArtworkProvider = @Sendable (_ artworkKey: String) async -> Data?
