import AppIntents

/// What the playback intents ask of the app's player. The app process registers one with
/// ``PlaybackIntentRouter``; the widget extension only declares the intents, which run in the app.
@MainActor
protocol PlaybackIntentHandling: AnyObject {
    func togglePlayback() async
}

/// Hands playback intents to the app's player. Widgets, controls and Shortcuts all reach the
/// player through here, so they share one coordinator with the app's UI and CarPlay.
@MainActor
enum PlaybackIntentRouter {
    /// Set by the app once its player exists. It is never set in the widget extension, where
    /// ``AudioPlaybackIntent``s don't run.
    static var handler: (any PlaybackIntentHandling)?

    /// The registered handler, or ``PlaybackIntentError/playerUnavailable`` if there is none.
    static func requireHandler() throws -> any PlaybackIntentHandling {
        guard let handler else { throw PlaybackIntentError.playerUnavailable }
        return handler
    }
}

enum PlaybackIntentError: Error, CustomLocalizedStringResourceConvertible {
    /// The app's player isn't set up, so the intent can't do anything.
    case playerUnavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .playerUnavailable: "Audiobookshelf can't control playback right now."
        }
    }
}

/// Plays or pauses the current book or episode. As an ``AudioPlaybackIntent`` it runs in the
/// app process, even when a widget or control in the extension starts it.
struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    // Hidden from Shortcuts until the app registers its player (#18, #56).
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try await PlaybackIntentRouter.requireHandler().togglePlayback()
        return .result()
    }
}
