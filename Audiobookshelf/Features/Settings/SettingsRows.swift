import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

#if os(iOS)
    import CoreHaptics

    /// Whether this device can play haptics. iPads (and Macs) have no Taptic Engine, so the
    /// haptic settings would do nothing there.
    enum HapticsSupport {
        static let isAvailable = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }
#endif

/// A toggle with a title and, optionally, the legacy info-dialog text under it. VoiceOver
/// reads the help as the hint.
struct SettingToggle: View {
    let titleKey: String
    var helpKey: String?
    @Binding var isOn: Bool

    init(_ titleKey: String, help helpKey: String? = nil, isOn: Binding<Bool>) {
        self.titleKey = titleKey
        self.helpKey = helpKey
        _isOn = isOn
    }

    var body: some View {
        let toggle = Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: ABSSpacing.xxSmall) {
                Text(verbatim: L10n.string(titleKey))
                if let helpKey {
                    Text(verbatim: L10n.string(helpKey))
                        .font(.footnote)
                        .foregroundStyle(ABSColor.mutedForeground)
                        .accessibilityHidden(true)
                }
            }
        }
        if let helpKey {
            toggle.accessibilityHint(Text(verbatim: L10n.string(helpKey)))
        } else {
            toggle
        }
    }
}

/// A picker over enum cases, labelled with localized names.
struct SettingPicker<Value: Hashable>: View {
    let titleKey: String
    let options: [Value]
    let label: (Value) -> String
    @Binding var selection: Value

    var body: some View {
        Picker(selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(verbatim: label(option)).tag(option)
            }
        } label: {
            Text(verbatim: L10n.string(titleKey))
        }
    }
}

/// Jump interval picker with the legacy short labels ("10s", "2m"), read out in full.
struct JumpIntervalPicker: View {
    let titleKey: String
    let options: [Int]
    @Binding var seconds: Int
    @Environment(\.locale) private var locale

    var body: some View {
        Picker(selection: $seconds) {
            ForEach(options, id: \.self) { value in
                Text(verbatim: Self.text(value, locale: locale))
                    .accessibilityLabel(Text(verbatim: JumpIntervalLabel(seconds: value).spokenText(locale: locale)))
                    .tag(value)
            }
        } label: {
            Text(verbatim: L10n.string(titleKey))
        }
        .accessibilityValue(Text(verbatim: JumpIntervalLabel(seconds: seconds).spokenText(locale: locale)))
    }

    static func text(_ seconds: Int, locale: Locale) -> String {
        let label = JumpIntervalLabel(seconds: seconds)
        let key = label.unit == .minutes ? "UnitMinutesShort" : "UnitSecondsShort"
        return L10n.string(key, label.formattedValue(locale: locale))
    }
}

/// A length picker (presets, end of chapter, custom) with a minutes stepper for the custom
/// time, replacing the legacy length modals. `customMinutes` must clamp to
/// ``SettingsViewModel/customMinutesRange``, as the view model's properties do.
struct DurationChoicePicker: View {
    let titleKey: String
    let choices: [DurationChoice]
    @Binding var selection: DurationChoice
    @Binding var customMinutes: Int
    @Environment(\.locale) private var locale

    var body: some View {
        Picker(selection: $selection) {
            ForEach(choices, id: \.self) { choice in
                Text(verbatim: text(choice, spoken: false))
                    .accessibilityLabel(Text(verbatim: text(choice, spoken: true)))
                    .tag(choice)
            }
        } label: {
            Text(verbatim: L10n.string(titleKey))
        }
        .accessibilityValue(Text(verbatim: text(selection, spoken: true)))
        if selection == .custom {
            Stepper(value: $customMinutes, in: SettingsViewModel.customMinutesRange) {
                AdaptiveStack(spacing: ABSSpacing.small) {
                    Text(verbatim: L10n.string("LabelCustomTime"))
                    Text(verbatim: MinutesFormatting.string(minutes: customMinutes, locale: locale))
                        .monospacedDigit()
                        .foregroundStyle(ABSColor.mutedForeground)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: L10n.string("LabelCustomTime")))
            .accessibilityValue(
                Text(verbatim: MinutesFormatting.string(minutes: customMinutes, spoken: true, locale: locale))
            )
            .accessibilityAdjustableAction { direction in
                // The view model clamps to the stepper's range.
                switch direction {
                case .increment: customMinutes += 1
                case .decrement: customMinutes -= 1
                @unknown default: break
                }
            }
        }
    }

    private func text(_ choice: DurationChoice, spoken: Bool) -> String {
        switch choice {
        case .minutes(let minutes): MinutesFormatting.string(minutes: minutes, spoken: spoken, locale: locale)
        case .endOfChapter: L10n.string("LabelEndOfChapter")
        case .custom: L10n.string("LabelCustomTime")
        }
    }
}

// MARK: - Option names

extension AppTheme {
    var settingsLabel: String {
        switch self {
        case .system: L10n.string("LabelThemeSystem")
        case .light: L10n.string("LabelThemeLight")
        case .dark: L10n.string("LabelThemeDark")
        case .black: L10n.string("LabelThemeBlack")
        }
    }
}

extension HapticFeedback {
    var settingsLabel: String {
        switch self {
        case .off: L10n.string("LabelOff")
        case .light: L10n.string("LabelLight")
        case .medium: L10n.string("LabelMedium")
        case .heavy: L10n.string("LabelHeavy")
        }
    }
}

extension ShakeSensitivity {
    var settingsLabel: String {
        switch self {
        case .veryLow: L10n.string("LabelVeryLow")
        case .low: L10n.string("LabelLow")
        case .medium: L10n.string("LabelMedium")
        case .high: L10n.string("LabelHigh")
        case .veryHigh: L10n.string("LabelVeryHigh")
        }
    }
}

extension CellularPolicy {
    /// Legacy order: ask, always, never.
    static let settingsOrder: [CellularPolicy] = [.ask, .always, .never]

    var settingsLabel: String {
        switch self {
        case .ask: L10n.string("LabelAskConfirmation")
        case .always: L10n.string("LabelAlways")
        case .never: L10n.string("LabelNever")
        }
    }
}
