import AppIntents

/// What the playback intents ask of the app's player. The app process registers one with
/// ``PlaybackIntentRouter``; the widget extension only declares the intents, which run in the app.
@MainActor
protocol PlaybackIntentHandling: AnyObject {
    /// Resumes the current item, or starts the last-played one.
    func resume() async throws
    func pause() async throws
    func togglePlayback() async throws
    /// Jumps by `seconds`, or by the user's interval for the direction when `nil`.
    func jump(forward: Bool, seconds: Int?) async throws
    /// Starts a sleep timer of `minutes`, or to the end of the chapter when `nil`.
    func setSleepTimer(minutes: Int?) async throws
    func setSpeed(_ rate: Double) async throws
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

/// Why a playback intent failed, shown by Siri and Shortcuts. The strings are in the `AppIntents`
/// table (`Localization/intents/`), which the app and the widget extension both bundle.
enum PlaybackIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    /// The app's player isn't set up, so the intent can't do anything.
    case playerUnavailable
    /// Nothing has played on this account yet, or nobody is signed in.
    case nothingToResume
    /// Nothing is loaded to control.
    case nothingPlaying
    /// The current playback has no sleep timer.
    case sleepTimerUnavailable
    /// End of chapter was asked for with no chapter end ahead.
    case noChapterEnd
    /// A jump's target track couldn't load.
    case jumpFailed
    /// Playback didn't start (blocked by the streaming setting, or failed); the app shows why.
    case playbackFailed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .playerUnavailable: LocalizedStringResource("IntentErrorPlayerUnavailable", table: "AppIntents")
        case .nothingToResume: LocalizedStringResource("IntentErrorNothingToResume", table: "AppIntents")
        case .nothingPlaying: LocalizedStringResource("IntentErrorNothingPlaying", table: "AppIntents")
        case .sleepTimerUnavailable: LocalizedStringResource("IntentErrorSleepTimerUnavailable", table: "AppIntents")
        case .noChapterEnd: LocalizedStringResource("IntentErrorNoChapterEnd", table: "AppIntents")
        case .jumpFailed: LocalizedStringResource("IntentErrorJumpFailed", table: "AppIntents")
        case .playbackFailed: LocalizedStringResource("IntentErrorPlaybackFailed", table: "AppIntents")
        }
    }
}

// Every playback intent is an ``AudioPlaybackIntent``, so it runs in the app process even when a
// widget or control in the extension starts it. The app registers its player with
// ``PlaybackIntentRouter`` at launch; without one, each fails with
// ``PlaybackIntentError/playerUnavailable``.

/// Resumes the current book or episode, or the last one played.
struct ResumeListeningIntent: AudioPlaybackIntent {
    static let title = LocalizedStringResource("IntentResumeListeningTitle", table: "AppIntents")
    static let description = IntentDescription(
        LocalizedStringResource("IntentResumeListeningDescription", table: "AppIntents"))

    @MainActor
    func perform() async throws -> some IntentResult {
        try await PlaybackIntentRouter.requireHandler().resume()
        return .result()
    }
}

/// Pauses playback.
struct PauseIntent: AudioPlaybackIntent {
    static let title = LocalizedStringResource("IntentPauseTitle", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource("IntentPauseDescription", table: "AppIntents"))

    @MainActor
    func perform() async throws -> some IntentResult {
        try await PlaybackIntentRouter.requireHandler().pause()
        return .result()
    }
}

/// Plays or pauses the current book or episode.
struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title = LocalizedStringResource("IntentTogglePlaybackTitle", table: "AppIntents")
    static let description = IntentDescription(
        LocalizedStringResource("IntentTogglePlaybackDescription", table: "AppIntents"))

    @MainActor
    func perform() async throws -> some IntentResult {
        try await PlaybackIntentRouter.requireHandler().togglePlayback()
        return .result()
    }
}

/// Which way ``JumpIntent`` jumps.
enum JumpDirection: String, AppEnum {
    case forward, backward

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("IntentJumpDirection", table: "AppIntents"))
    static let caseDisplayRepresentations: [JumpDirection: DisplayRepresentation] = [
        .forward: DisplayRepresentation(title: LocalizedStringResource("IntentJumpForward", table: "AppIntents")),
        .backward: DisplayRepresentation(title: LocalizedStringResource("IntentJumpBack", table: "AppIntents")),
    ]
}

/// Jumps forward or back, by the user's jump interval unless the intent gives the seconds.
struct JumpIntent: AudioPlaybackIntent {
    static let title = LocalizedStringResource("IntentJumpTitle", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource("IntentJumpDescription", table: "AppIntents"))

    @Parameter(title: LocalizedStringResource("IntentJumpDirection", table: "AppIntents"), default: .forward)
    var direction: JumpDirection

    /// `nil` uses the user's jump interval for the direction.
    @Parameter(title: LocalizedStringResource("IntentJumpSeconds", table: "AppIntents"), inclusiveRange: (1, 3600))
    var seconds: Int?

    init() {}

    init(direction: JumpDirection, seconds: Int? = nil) {
        self.direction = direction
        self.seconds = seconds
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await PlaybackIntentRouter.requireHandler().jump(forward: direction == .forward, seconds: seconds)
        return .result()
    }
}

/// What ``SetSleepTimerIntent`` sets.
enum SleepTimerLength: String, AppEnum {
    case minutes, endOfChapter

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("IntentSleepTimerLength", table: "AppIntents"))
    static let caseDisplayRepresentations: [SleepTimerLength: DisplayRepresentation] = [
        .minutes: DisplayRepresentation(title: LocalizedStringResource("IntentSleepTimerMinutes", table: "AppIntents")),
        .endOfChapter: DisplayRepresentation(
            title: LocalizedStringResource("IntentSleepTimerEndOfChapter", table: "AppIntents")),
    ]
}

/// Starts a sleep timer for some minutes or to the end of the chapter, replacing any running one.
struct SetSleepTimerIntent: AudioPlaybackIntent {
    static let title = LocalizedStringResource("IntentSetSleepTimerTitle", table: "AppIntents")
    static let description = IntentDescription(
        LocalizedStringResource("IntentSetSleepTimerDescription", table: "AppIntents"))

    @Parameter(title: LocalizedStringResource("IntentSleepTimerLength", table: "AppIntents"), default: .minutes)
    var length: SleepTimerLength

    /// Used only for ``SleepTimerLength/minutes``; the app clamps it to its sleep timer range.
    @Parameter(
        title: LocalizedStringResource("IntentSleepTimerMinutes", table: "AppIntents"), default: 30,
        inclusiveRange: (1, 1440))
    var minutes: Int

    init() {}

    init(length: SleepTimerLength, minutes: Int = 30) {
        self.length = length
        self.minutes = minutes
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await PlaybackIntentRouter.requireHandler().setSleepTimer(minutes: length == .minutes ? minutes : nil)
        return .result()
    }
}

/// Sets the playback speed; the app rounds it to 0.1 and clamps it to its supported range.
struct SetPlaybackSpeedIntent: AudioPlaybackIntent {
    static let title = LocalizedStringResource("IntentSetPlaybackSpeedTitle", table: "AppIntents")
    static let description = IntentDescription(
        LocalizedStringResource("IntentSetPlaybackSpeedDescription", table: "AppIntents"))

    @Parameter(
        title: LocalizedStringResource("IntentPlaybackSpeed", table: "AppIntents"), default: 1,
        inclusiveRange: (0.5, 10))
    var speed: Double

    init() {}

    init(speed: Double) {
        self.speed = speed
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await PlaybackIntentRouter.requireHandler().setSpeed(speed)
        return .result()
    }
}
