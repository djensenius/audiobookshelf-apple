import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// Shake to reset, fade-out, reset feedback and the almost-done chime. Shaking and
/// vibration need an iPhone or iPad, so those rows are iOS only.
struct SleepTimerSettingsSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            #if os(iOS)
                SettingToggle(
                    "LabelDisableShakeToReset", help: "LabelDisableShakeToResetHelp",
                    isOn: $settings.disableShakeToResetSleepTimer)
                if !settings.disableShakeToResetSleepTimer {
                    SettingPicker(
                        titleKey: "LabelShakeSensitivity", options: ShakeSensitivity.allCases,
                        label: \.settingsLabel, selection: $settings.shakeSensitivity)
                }
            #endif
            SettingToggle(
                "LabelDisableAudioFadeOut", help: "LabelDisableAudioFadeOutHelp",
                isOn: $settings.disableSleepTimerFadeOut)
            #if os(iOS)
                SettingToggle(
                    "LabelDisableVibrateOnReset", help: "LabelDisableVibrateOnResetHelp",
                    isOn: $settings.disableSleepTimerResetFeedback)
            #endif
            SettingToggle(
                "LabelSleepTimerAlmostDoneChime", help: "LabelSleepTimerAlmostDoneChimeHelp",
                isOn: $settings.enableSleepTimerAlmostDoneChime)
        } header: {
            Text(verbatim: L10n.string("HeaderSleepTimerSettings"))
        }
    }
}

/// The auto sleep timer: its window, the timer length it starts, and the rewind after it
/// expires. As in legacy, the details show only while the auto sleep timer is on.
struct AutoSleepTimerSettingsSection: View {
    @Bindable var settings: AppSettings
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Section {
            SettingToggle("LabelAutoSleepTimer", help: "LabelAutoSleepTimerHelp", isOn: $settings.autoSleepTimer)
            if settings.autoSleepTimer {
                DatePicker(selection: $viewModel.autoSleepTimerStart, displayedComponents: .hourAndMinute) {
                    Text(verbatim: L10n.string("LabelStartTime"))
                }
                DatePicker(selection: $viewModel.autoSleepTimerEnd, displayedComponents: .hourAndMinute) {
                    Text(verbatim: L10n.string("LabelEndTime"))
                }
                if viewModel.isAutoSleepWindowEmpty {
                    Label {
                        Text(verbatim: L10n.string("MessageAutoSleepTimerWindowEmpty"))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(ABSColor.warning)
                    }
                    .font(.footnote)
                }
                DurationChoicePicker(
                    titleKey: "LabelSleepTimer", choices: SettingsViewModel.sleepTimerLengthChoices,
                    selection: $viewModel.sleepTimerLengthChoice, customMinutes: $viewModel.sleepTimerCustomMinutes)
                SettingToggle(
                    "LabelAutoSleepTimerAutoRewind", help: "LabelAutoSleepTimerAutoRewindHelp",
                    isOn: $settings.autoSleepTimerAutoRewind)
                if settings.autoSleepTimerAutoRewind {
                    DurationChoicePicker(
                        titleKey: "LabelAutoRewindTime", choices: SettingsViewModel.autoRewindLengthChoices,
                        selection: $viewModel.autoRewindLengthChoice,
                        customMinutes: $viewModel.autoRewindCustomMinutes)
                }
            }
        }
    }
}
