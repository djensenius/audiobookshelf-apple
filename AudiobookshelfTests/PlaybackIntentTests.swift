import Testing

@testable import Audiobookshelf

/// The shared playback intents (#88) reach the app's player through ``PlaybackIntentRouter``.
@MainActor @Suite(.serialized) struct PlaybackIntentTests {
    @Test func toggleFailsWithoutAPlayer() async {
        PlaybackIntentRouter.handler = nil
        await #expect(throws: PlaybackIntentError.self) {
            _ = try await TogglePlaybackIntent().perform()
        }
    }

    @Test func togglePausesAndResumesTheRegisteredPlayer() async throws {
        let playback = PreviewPlaybackControl(playing: true)
        let handler = PlaybackIntentHandler(playback: playback)
        PlaybackIntentRouter.handler = handler
        defer { PlaybackIntentRouter.handler = nil }

        _ = try await TogglePlaybackIntent().perform()
        #expect(!playback.isPlaybackRequested)
        _ = try await TogglePlaybackIntent().perform()
        #expect(playback.isPlaybackRequested)
    }
}
