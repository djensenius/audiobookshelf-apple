import ABSCore
import ABSData
import ABSPlayback
import Observation

/// A ``PlaybackScope``'s coordinator as the player screens drive it (through ``CurrentPlayback``).
/// Everything forwards to the coordinator, except ``resume(rewindingBy:)``, which goes through
/// the scope: a user resume, like a user play, also asks for the system's primary Now Playing
/// session. Remote commands reach the coordinator through the bridge, not through here.
///
/// Observation works as for the coordinator: every getter reads the coordinator's own properties.
@MainActor
final class ScopePlayback: PlayerPlaybackControlling {
    let coordinator: PlaybackCoordinator
    private weak var scope: PlaybackScope?

    init(scope: PlaybackScope) {
        self.scope = scope
        coordinator = scope.coordinator
    }

    var phase: PlaybackCoordinator.Phase { coordinator.phase }
    var mediaKey: MediaKey? { coordinator.mediaKey }
    var session: PlaybackSession? { coordinator.session }
    var restoredRecord: LastPlayedRecord? { coordinator.restoredRecord }
    var error: PlaybackCoordinatorError? { coordinator.error }
    var currentTime: Double { coordinator.currentTime }
    var duration: Double { coordinator.duration }
    var rate: Double { coordinator.rate }
    var isPlaying: Bool { coordinator.isPlaying }
    var isBuffering: Bool { coordinator.isBuffering }
    var isPlaybackRequested: Bool { coordinator.isPlaybackRequested }
    var timeline: PlaybackTimeline? { coordinator.timeline }
    var chapterIndex: Int? { coordinator.chapterIndex }
    var chapter: Chapter? { coordinator.chapter }
    var chapterRange: TimelineRange? { coordinator.chapterRange }
    var chapterElapsed: Double? { coordinator.chapterElapsed }
    var chapterRemaining: Double? { coordinator.chapterRemaining }

    func resume(rewindingBy seconds: Double?) async {
        if let scope {
            await scope.resume(rewindingBy: seconds)
        } else {
            await coordinator.resume(rewindingBy: seconds)
        }
    }

    func pause() {
        coordinator.pause()
    }

    @discardableResult func seek(to time: Double) async -> Double? {
        await coordinator.seek(to: time)
    }

    @discardableResult func jump(by offset: Double) async -> Double? {
        await coordinator.jump(by: offset)
    }

    @discardableResult func jumpOutcome(by offset: Double) async -> JumpOutcome {
        await coordinator.jumpOutcome(by: offset)
    }

    func setRate(_ rate: Double) {
        coordinator.setRate(rate)
    }

    func stop(reason: PlaybackStopReason) {
        coordinator.stop(reason: reason)
    }

    func confirmMeteredStreaming() async {
        if let scope {
            await scope.confirmMeteredStreaming()
        } else {
            await coordinator.confirmMeteredStreaming()
        }
    }

    func declineMeteredStreaming() {
        coordinator.declineMeteredStreaming()
    }

    func handleStreamReset(sessionID: String) {
        coordinator.handleStreamReset(sessionID: sessionID)
    }
}
