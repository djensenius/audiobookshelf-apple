import ABSCore
import ABSData
import ABSPlayback
import Foundation
import Observation

@testable import ABSAppModel

/// A hand-driven ``PlayerPlaybackControlling`` that records its commands. Chapter state is derived
/// from ``timeline`` and ``currentTime`` the way ``PlaybackCoordinator`` derives it.
@MainActor
@Observable
final class FakePlaybackControl: PlayerPlaybackControlling {
    enum Call: Equatable {
        case resume(rewindingBy: Double?)
        case pause
        case seek(Double)
        case jump(Double)
        case setRate(Double)
        case stop(PlaybackStopReason)
        case confirmMeteredStreaming
        case declineMeteredStreaming
    }

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
    var isWaitingForNetwork = false
    var timeline: PlaybackTimeline?
    /// Whether seeks land; one that doesn't returns `nil` and leaves playback where it was.
    var seeksLand = true
    /// Whether the sleep timer's play is accepted; a refused one leaves playback paused, as when the audio session
    /// won't activate.
    var playsStart = true
    /// Makes ``resume(rewindingBy:)`` fail as the coordinator's does when the streaming policy blocks
    /// it or the audio session won't activate: it sets ``error`` and leaves play unrequested.
    var resumeFailure: PlaybackCoordinatorError?
    /// The error a confirmed metered stream leaves, as the coordinator's replayed play does: `nil`
    /// once it plays, or a block when the policy changed to "never" meanwhile.
    var confirmFailure: PlaybackCoordinatorError?
    /// How a jump ends, as the coordinator's can: landing, deferred because it was queued or
    /// superseded, or failed because the target track wouldn't load.
    enum JumpBehavior { case lands, superseded, fails }
    var jumpBehavior = JumpBehavior.lands
    private(set) var calls: [Call] = []

    var chapterIndex: Int? { timeline?.currentChapterIndex(at: currentTime) }
    var chapter: Chapter? { timeline?.currentChapter(at: currentTime) }
    var chapterRange: TimelineRange? {
        guard let timeline, chapterIndex != nil else { return nil }
        return timeline.progressRange(at: currentTime, chapterTrack: true)
    }
    var chapterElapsed: Double? { chapterRange?.elapsed(at: currentTime) }
    var chapterRemaining: Double? { chapterRange?.remaining(at: currentTime) }

    func resume(rewindingBy seconds: Double?) async {
        calls.append(.resume(rewindingBy: seconds))
        if let resumeFailure {
            error = resumeFailure
            return
        }
        isPlaybackRequested = true
    }

    func pause() {
        calls.append(.pause)
        isPlaybackRequested = false
        isPlaying = false
    }

    func seek(to time: Double) async -> Double? {
        calls.append(.seek(time))
        guard seeksLand else { return nil }
        currentTime = timeline?.clamp(time) ?? max(time, 0)
        return currentTime
    }

    func jump(by offset: Double) async -> Double? {
        await jumpOutcome(by: offset).landedTime
    }

    func jumpOutcome(by offset: Double) async -> JumpOutcome {
        calls.append(.jump(offset))
        switch jumpBehavior {
        case .superseded: return .deferred
        case .fails: return .failed
        case .lands:
            currentTime = timeline?.clamp(currentTime + offset) ?? max(currentTime + offset, 0)
            return .landed(currentTime)
        }
    }

    func setRate(_ rate: Double) {
        calls.append(.setRate(rate))
        self.rate = rate
    }

    func stop(reason: PlaybackStopReason) {
        calls.append(.stop(reason))
        phase = .idle
        mediaKey = nil
        session = nil
        restoredRecord = nil
        timeline = nil
        isPlaying = false
        isPlaybackRequested = false
    }

    /// Like the coordinator's, it only replays a play while the error is a confirmation.
    func confirmMeteredStreaming() async {
        calls.append(.confirmMeteredStreaming)
        guard case .streamingNeedsConfirmation = error else { return }
        error = confirmFailure
    }

    /// Like the coordinator's, it only clears a confirmation.
    func declineMeteredStreaming() {
        calls.append(.declineMeteredStreaming)
        guard case .streamingNeedsConfirmation = error else { return }
        error = nil
    }

    // MARK: Fixtures

    nonisolated static let serverID = UUID(uuidString: "6F1C0E8A-2B7D-4C1E-9A43-1D2E3F405162")!

    nonisolated static func key(item: String = "li_book", episode: String? = nil) -> MediaKey {
        MediaKey(serverConnectionID: serverID, libraryItemId: item, episodeId: episode)
    }

    /// Chapters at 0–100, 100–250 and 250–400 over a 400-second track.
    nonisolated static let chapters = [
        Chapter(id: 0, start: 0, end: 100, title: "Opening"),
        Chapter(id: 1, start: 100, end: 250, title: "Middle"),
        Chapter(id: 2, start: 250, end: 400, title: "Ending"),
    ]

    nonisolated static func bookSession(
        item: String = "li_book", id: String? = nil, chapters: [Chapter] = chapters
    ) -> PlaybackSession {
        PlaybackSession(
            id: id ?? "sess_\(item)", libraryItemId: item, mediaType: .book,
            mediaMetadata: .book(BookMetadata(title: "Dune")), chapters: chapters, displayTitle: "Dune",
            displayAuthor: "Frank Herbert", coverPath: "/metadata/items/\(item)/cover.jpg", duration: 400,
            audioTracks: [AudioTrack(index: 1, startOffset: 0, duration: 400, mimeType: "audio/mpeg")],
            libraryItem: LibraryItem(id: item, libraryId: "lib", updatedAt: 1_700_000_000_000, mediaType: .book))
    }

    /// Makes `session` the loaded item at `time`.
    func load(_ session: PlaybackSession, at time: Double = 0, playing: Bool = false) {
        phase = .loaded
        isBuffering = false
        setKey(for: session)
        self.session = session
        restoredRecord = nil
        let timeline = PlaybackTimeline(session: session)
        self.timeline = timeline
        duration = timeline.duration
        currentTime = time
        isPlaying = playing
        isPlaybackRequested = playing
    }

    /// Makes `session` the current item while the engine loads it, as the coordinator does in
    /// `.starting`: the session is set, the timeline isn't, and the duration isn't known yet.
    func start(_ session: PlaybackSession, at time: Double = 0) {
        phase = .starting
        setKey(for: session)
        self.session = session
        timeline = nil
        duration = 0
        currentTime = time
        isBuffering = true
        isPlaybackRequested = true
    }

    /// Like the coordinator, the key is only set when the item changes, not when it restarts.
    private func setKey(for session: PlaybackSession) {
        let key = Self.key(item: session.libraryItemId, episode: session.episodeId)
        if mediaKey != key { mediaKey = key }
    }

    /// Makes `record` the restored, unloaded item.
    func restore(_ record: LastPlayedRecord) {
        phase = .unloaded
        isBuffering = false
        mediaKey = record.key
        session = nil
        restoredRecord = record
        timeline = nil
        duration = record.duration ?? 0
        currentTime = record.position
    }

    func clearCalls() {
        calls.removeAll()
    }
}
