import ABSAppModel

/// Runs the shared playback intents (`AudiobookshelfShared/Intents`) on the app's player, the
/// ``PlaybackCoordinator`` the player screens and CarPlay use. Whoever builds the coordinator
/// registers one with ``PlaybackIntentRouter``.
@MainActor
final class PlaybackIntentHandler: PlaybackIntentHandling {
    private let playback: any PlayerPlaybackControlling

    init(playback: any PlayerPlaybackControlling) {
        self.playback = playback
    }

    /// Pauses while play is requested (also while starting or stalled), else resumes, like the
    /// player's play/pause button.
    func togglePlayback() async {
        if playback.isPlaybackRequested {
            playback.pause()
        } else {
            await playback.resume(rewindingBy: nil)
        }
    }
}
