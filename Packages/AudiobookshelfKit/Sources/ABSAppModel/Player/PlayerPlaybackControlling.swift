import ABSCore
import ABSData
import ABSPlayback
import Observation

/// The playback state and commands ``PlayerViewModel`` needs, so the player screens can be tested
/// and previewed with a fake. ``PlaybackCoordinator`` conforms; see it for what each member means.
///
/// Conformers must be `@Observable`: the view model reads these properties inside SwiftUI's
/// observation tracking and does not cache them.
@MainActor
public protocol PlayerPlaybackControlling: AnyObject, Observable {
    var phase: PlaybackCoordinator.Phase { get }
    var mediaKey: MediaKey? { get }
    var session: PlaybackSession? { get }
    var restoredRecord: LastPlayedRecord? { get }
    var error: PlaybackCoordinatorError? { get }
    /// ``PlaybackCoordinator/startGeneration``: tells a pending start apart from one begun after a stop.
    var startGeneration: Int { get }
    /// Global seconds.
    var currentTime: Double { get }
    var duration: Double { get }
    var rate: Double { get }
    var isPlaying: Bool { get }
    var isBuffering: Bool { get }
    /// The play intent: `true` while starting, playing or stalled with play requested.
    var isPlaybackRequested: Bool { get }
    /// Whether recovery is waiting for the network before its next attempt.
    var isWaitingForNetwork: Bool { get }
    /// The loaded timeline; `nil` unless media is loaded.
    var timeline: PlaybackTimeline? { get }
    var chapterIndex: Int? { get }
    var chapter: Chapter? { get }
    var chapterRange: TimelineRange? { get }
    var chapterElapsed: Double? { get }
    var chapterRemaining: Double? { get }

    func resume(rewindingBy seconds: Double?) async
    func pause()
    @discardableResult func seek(to time: Double) async -> Double?
    @discardableResult func jump(by offset: Double) async -> Double?
    /// Jumps and reports how this jump ended, telling a target that failed to load apart from a
    /// queued or superseded jump.
    @discardableResult func jumpOutcome(by offset: Double) async -> JumpOutcome
    func setRate(_ rate: Double)
    func stop(reason: PlaybackStopReason)
    /// Replays the play a `.streamingNeedsConfirmation` error blocked, allowing the metered path.
    func confirmMeteredStreaming() async
    /// Clears a `.streamingNeedsConfirmation` error without playing.
    func declineMeteredStreaming()
    /// The server restarted the transcode of session `sessionID` (`stream_reset`); see
    /// ``PlaybackCoordinator/handleStreamReset(sessionID:)``.
    func handleStreamReset(sessionID: String)
}

extension PlayerPlaybackControlling {
    /// Fakes and previews stream nothing, so there is nothing to reset.
    public func handleStreamReset(sessionID: String) {}
}

extension PlaybackCoordinator: PlayerPlaybackControlling {}
