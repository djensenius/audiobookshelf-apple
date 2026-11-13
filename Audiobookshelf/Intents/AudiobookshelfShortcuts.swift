import AppIntents

/// Siri and Spotlight phrases for the playback intents. Every phrase names the app with
/// `\(.applicationName)`, as App Shortcuts require.
///
/// Phrases are English literals: App Shortcuts look up their translations in an
/// `AppShortcuts.xcstrings` keyed by the English phrase (see `docs/localization.md`). Titles come
/// from the `AppIntents` table like the intents' other strings.
struct AudiobookshelfShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResumeListeningIntent(),
            phrases: [
                "Resume listening in \(.applicationName)",
                "Resume \(.applicationName)",
                "Continue my book in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("IntentResumeListeningTitle", table: "AppIntents"),
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlayBookIntent(),
            phrases: [
                "Play \(\.$book) in \(.applicationName)",
                "Listen to \(\.$book) in \(.applicationName)",
                "Play a book in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("IntentPlayBookTitle", table: "AppIntents"),
            systemImageName: "book"
        )
        AppShortcut(
            intent: PlayEpisodeIntent(),
            phrases: [
                "Play \(\.$episode) in \(.applicationName)",
                "Play an episode in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("IntentPlayEpisodeTitle", table: "AppIntents"),
            systemImageName: "mic"
        )
        AppShortcut(
            intent: PauseIntent(),
            phrases: ["Pause \(.applicationName)"],
            shortTitle: LocalizedStringResource("IntentPauseTitle", table: "AppIntents"),
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: TogglePlaybackIntent(),
            phrases: ["Play or pause \(.applicationName)"],
            shortTitle: LocalizedStringResource("IntentTogglePlaybackTitle", table: "AppIntents"),
            systemImageName: "playpause.fill"
        )
        AppShortcut(
            intent: JumpIntent(),
            phrases: [
                "Jump \(\.$direction) in \(.applicationName)",
                "Skip \(\.$direction) in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("IntentJumpTitle", table: "AppIntents"),
            systemImageName: "goforward"
        )
        AppShortcut(
            intent: SetSleepTimerIntent(),
            phrases: ["Set a sleep timer in \(.applicationName)"],
            shortTitle: LocalizedStringResource("IntentSetSleepTimerTitle", table: "AppIntents"),
            systemImageName: "moon.zzz"
        )
        AppShortcut(
            intent: SetPlaybackSpeedIntent(),
            phrases: ["Change the speed in \(.applicationName)"],
            shortTitle: LocalizedStringResource("IntentSetPlaybackSpeedTitle", table: "AppIntents"),
            systemImageName: "gauge.with.dots.needle.67percent"
        )
    }
}
