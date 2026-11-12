import ABSAppModel
import ABSUI
import SwiftUI

/// A sleep timer length chooser (port of the lists in `SleepTimerModal.vue` and
/// `SleepTimerLengthModal.vue`): one row per preset, End of Chapter when it's offered, and a custom
/// time stepper with a Set Timer button. Each choice calls `choose` at once, with
/// ``ABSAppModel/DurationChoice/minutes(_:)`` or ``ABSAppModel/DurationChoice/endOfChapter``, never
/// `.custom`. Made of `Section`s, for a `List` or `Form`.
struct SleepTimerLengthPicker: View {
    var presets: [Int] = SleepTimerPanelModel.presetMinutes
    /// Whether to show End of Chapter. Called by its row alone: it may read the playback time,
    /// which changes every tick.
    var offersEndOfChapter: () -> Bool = { true }
    let choose: (DurationChoice) -> Void

    @State private var customMinutes = SleepTimerPanelModel.customMinutesRange.lowerBound
    @Environment(\.locale) private var locale

    var body: some View {
        Section {
            ForEach(presets, id: \.self) { minutes in
                Button {
                    choose(.minutes(minutes))
                } label: {
                    row(MinutesFormatting.string(minutes: minutes, locale: locale))
                }
                .accessibilityLabel(
                    Text(verbatim: MinutesFormatting.string(minutes: minutes, spoken: true, locale: locale)))
            }
            EndOfChapterRow(isOffered: offersEndOfChapter) {
                choose(.endOfChapter)
            }
        }
        Section {
            Stepper(value: $customMinutes, in: SleepTimerPanelModel.customMinutesRange) {
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
                let range = SleepTimerPanelModel.customMinutesRange
                switch direction {
                case .increment: customMinutes = min(customMinutes + 1, range.upperBound)
                case .decrement: customMinutes = max(customMinutes - 1, range.lowerBound)
                @unknown default: break
                }
            }
            Button {
                choose(.minutes(customMinutes))
            } label: {
                row(L10n.string("ButtonSetTimer"))
            }
        }
    }
}

/// A full-width, tappable row label.
private func row(_ text: String) -> some View {
    Text(verbatim: text)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
}

/// The End of Chapter row, apart so only it redraws when the playback time ticks.
private struct EndOfChapterRow: View {
    let isOffered: () -> Bool
    let action: () -> Void

    var body: some View {
        if isOffered() {
            Button(action: action) {
                row(L10n.string("LabelEndOfChapter"))
            }
        }
    }
}

#Preview("Length picker") {
    List {
        SleepTimerLengthPicker { _ in }
    }
}

#Preview("Length picker, accessibility size") {
    List {
        SleepTimerLengthPicker(offersEndOfChapter: { false }) { _ in }
    }
    .dynamicTypeSize(.accessibility3)
}
