import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The Settings screen, a port of `pages/settings.vue`: display, playback, sleep timer,
/// data and language settings. On iOS it is pushed from the app; on macOS it is the
/// `Settings` scene. Every control writes to ``AppSettings``, so changes apply live.
/// Where each legacy setting went is in `docs/settings.md`.
struct SettingsView: View {
    @State private var viewModel: SettingsViewModel

    init(settings: AppSettings) {
        _viewModel = State(initialValue: SettingsViewModel(settings: settings))
    }

    var body: some View {
        let settings = viewModel.settings
        Form {
            Group {
                DisplaySettingsSection(settings: settings, viewModel: viewModel)
                PlaybackSettingsSection(settings: settings, viewModel: viewModel)
                SleepTimerSettingsSection(settings: settings)
                AutoSleepTimerSettingsSection(settings: settings, viewModel: viewModel)
                DataSettingsSection(settings: settings)
                LanguageSettingsSection()
            }
            #if os(iOS)
                .listRowBackground(Rectangle().fill(ABSColor.secondarySurface))
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle(Text(verbatim: L10n.string("HeaderSettings")))
        #if os(iOS)
            .scrollContentBackground(.hidden)
            .absBackground()
            // Lets the user feel the strength they picked.
            .absHaptic(settings.hapticFeedback, trigger: settings.hapticFeedback)
        #else
            .frame(minWidth: 460, idealWidth: 540, minHeight: 360, idealHeight: 640)
        #endif
    }
}

// MARK: - Previews

/// Settings in a throwaway store, with the auto sleep timer on so every row shows.
private struct SettingsPreview: View {
    @State private var settings: AppSettings

    init(theme: AppTheme) {
        let defaults = UserDefaults(suiteName: "SettingsViewPreview.\(theme.rawValue)") ?? .standard
        let settings = AppSettings(defaults: defaults)
        settings.theme = theme
        settings.autoSleepTimer = true
        settings.autoSleepTimerAutoRewind = true
        _settings = State(initialValue: settings)
    }

    var body: some View {
        NavigationStack {
            SettingsView(settings: settings)
        }
        .absTheme(settings.theme)
    }
}

#Preview("Light") {
    SettingsPreview(theme: .light)
}

#Preview("Dark") {
    SettingsPreview(theme: .dark)
}

#Preview("Black") {
    SettingsPreview(theme: .black)
}

#Preview("AX5") {
    SettingsPreview(theme: .system)
        .dynamicTypeSize(.accessibility5)
}
