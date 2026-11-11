import ABSAppModel
import ABSCore
import ABSData
import ABSPlayback
import Foundation
import Observation

/// A hand-driven ``PlayerPlaybackControlling`` for previews: a loaded book with three chapters that
/// answers commands without playing anything.
@MainActor @Observable
final class PreviewPlaybackControl: PlayerPlaybackControlling {
    var phase: PlaybackCoordinator.Phase = .idle
    var mediaKey: MediaKey?
    var session: PlaybackSession?
    var restoredRecord: LastPlayedRecord?
    var error: PlaybackCoordinatorError?
    var currentTime: Double = 0
    var duration: Double = 0
    var rate: Double = 1
    var isPlaying = false
    var isBuffering = false
    var isPlaybackRequested = false
    var timeline: PlaybackTimeline?

    var chapterIndex: Int? { timeline?.currentChapterIndex(at: currentTime) }
    var chapter: Chapter? { timeline?.currentChapter(at: currentTime) }
    var chapterRange: TimelineRange? {
        guard let timeline, chapterIndex != nil else { return nil }
        return timeline.progressRange(at: currentTime, chapterTrack: true)
    }
    var chapterElapsed: Double? { chapterRange?.elapsed(at: currentTime) }
    var chapterRemaining: Double? { chapterRange?.remaining(at: currentTime) }

    /// - Parameters:
    ///   - loaded: Whether a book is loaded; `false` leaves nothing playing.
    ///   - time: The position, in seconds of the 4-hour book.
    init(loaded: Bool = true, at time: Double = 4_000, playing: Bool = false, buffering: Bool = false) {
        guard loaded else { return }
        let session = Self.session
        let timeline = PlaybackTimeline(session: session)
        phase = .loaded
        mediaKey = MediaKey(serverConnectionID: UUID(), libraryItemId: session.libraryItemId)
        self.session = session
        self.timeline = timeline
        duration = timeline.duration
        currentTime = time
        isPlaying = playing && !buffering
        isPlaybackRequested = playing
        isBuffering = buffering
    }

    func resume(rewindingBy seconds: Double?) async {
        isPlaybackRequested = true
        isPlaying = true
    }

    func pause() {
        isPlaybackRequested = false
        isPlaying = false
    }

    func seek(to time: Double) async -> Double? {
        currentTime = timeline?.clamp(time) ?? max(time, 0)
        return currentTime
    }

    func jump(by offset: Double) async -> Double? {
        await seek(to: currentTime + offset)
    }

    func setRate(_ rate: Double) {
        self.rate = rate
    }

    func stop(reason: PlaybackStopReason) {
        phase = .idle
        mediaKey = nil
        session = nil
        timeline = nil
        isPlaying = false
        isPlaybackRequested = false
    }

    private static let session = PlaybackSession(
        id: "preview", libraryItemId: "li_preview", mediaType: .book, mediaMetadata: .book(BookMetadata(title: "Dune")),
        chapters: [
            Chapter(id: 0, start: 0, end: 3_600, title: "Book One: Dune"),
            Chapter(id: 1, start: 3_600, end: 9_000, title: "Book Two: Muad'Dib"),
            Chapter(id: 2, start: 9_000, end: 14_400, title: "Book Three: The Prophet"),
        ],
        displayTitle: "Dune", displayAuthor: "Frank Herbert", duration: 14_400,
        audioTracks: [AudioTrack(index: 1, startOffset: 0, duration: 14_400, mimeType: "audio/mpeg")])
}

extension PlayerViewModel {
    /// A view model over ``PreviewPlaybackControl``, with settings in a throwaway defaults suite.
    static func preview(
        loaded: Bool = true, at time: Double = 4_000, playing: Bool = false, buffering: Bool = false
    ) -> PlayerViewModel {
        let defaults = UserDefaults(suiteName: "PlayerPreview") ?? .standard
        return PlayerViewModel(
            playback: PreviewPlaybackControl(loaded: loaded, at: time, playing: playing, buffering: buffering),
            settings: AppSettings(defaults: defaults))
    }
}
