import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

#if os(iOS)
    import UIKit
#endif

/// Bookshelf view, theme and, on devices that can play them, haptics.
struct DisplaySettingsSection: View {
    @Bindable var settings: AppSettings
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Section {
            SettingToggle("LabelUseBookshelfView", isOn: $viewModel.useBookshelfView)
            SettingPicker(
                titleKey: "LabelTheme", options: AppTheme.allCases, label: \.settingsLabel, selection: $settings.theme)
            #if os(iOS)
                if HapticsSupport.isAvailable {
                    SettingPicker(
                        titleKey: "LabelHapticFeedback", options: HapticFeedback.allCases, label: \.settingsLabel,
                        selection: $settings.hapticFeedback)
                }
            #endif
        } header: {
            Text(verbatim: L10n.string("HeaderUserInterfaceSettings"))
        }
    }
}

/// Jump intervals, auto-rewind, mp3 index seeking and seeking from system media controls.
struct PlaybackSettingsSection: View {
    @Bindable var settings: AppSettings
    let viewModel: SettingsViewModel

    var body: some View {
        Section {
            JumpIntervalPicker(
                titleKey: "LabelJumpBackwardsTime", options: viewModel.jumpBackwardsOptions,
                seconds: $settings.jumpBackwardsTime)
            JumpIntervalPicker(
                titleKey: "LabelJumpForwardsTime", options: viewModel.jumpForwardOptions,
                seconds: $settings.jumpForwardTime)
            SettingToggle("LabelDisableAutoRewind", isOn: $settings.disableAutoRewind)
            SettingToggle(
                "LabelEnableMp3IndexSeeking", help: "LabelEnableMp3IndexSeekingHelp",
                isOn: $settings.enableMp3IndexSeeking)
            SettingToggle(
                "LabelAllowSeekingOnMediaControls", help: "LabelAllowSeekingOnMediaControlsHelp",
                isOn: $settings.allowSeekingOnMediaControls)
        } header: {
            Text(verbatim: L10n.string("HeaderPlaybackSettings"))
        }
    }
}

/// Cellular streaming and download policies. Low Data Mode (and, on a Mac, expensive
/// paths) count as cellular; see `NetworkPolicy`.
struct DataSettingsSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            SettingPicker(
                titleKey: "LabelDownloadUsingCellular", options: CellularPolicy.settingsOrder, label: \.settingsLabel,
                selection: $settings.downloadUsingCellular)
            SettingPicker(
                titleKey: "LabelStreamingUsingCellular", options: CellularPolicy.settingsOrder,
                label: \.settingsLabel, selection: $settings.streamingUsingCellular)
        } header: {
            Text(verbatim: L10n.string("HeaderDataSettings"))
        } footer: {
            #if os(macOS)
                Text(verbatim: L10n.string("MessageCellularSettingsHelpMac"))
            #else
                Text(verbatim: L10n.string("MessageCellularSettingsHelp"))
            #endif
        }
    }
}

/// The app's language comes from the system's per-app language setting, which replaces
/// the legacy in-app picker.
struct LanguageSettingsSection: View {
    @Environment(\.locale) private var locale
    #if os(iOS)
        @Environment(\.openURL) private var openURL
    #endif

    var body: some View {
        Section {
            LabeledContent {
                Text(verbatim: currentLanguage)
            } label: {
                Text(verbatim: L10n.string("LabelLanguage"))
            }
            #if os(iOS)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Text(verbatim: L10n.string("ButtonOpenSettings"))
                }
            #endif
        } footer: {
            #if os(macOS)
                Text(verbatim: L10n.string("MessageLanguageSettingsHelpMac"))
            #else
                Text(verbatim: L10n.string("MessageLanguageSettingsHelp"))
            #endif
        }
    }

    /// The localization the app is running in, named in the current locale.
    private var currentLanguage: String {
        let identifier = Bundle.main.preferredLocalizations.first ?? "en"
        return (locale.localizedString(forIdentifier: identifier) ?? identifier).capitalized(with: locale)
    }
}
