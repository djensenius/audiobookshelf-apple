import ABSAppModel
import ABSUI
import SwiftUI

/// How the player writes a playback rate: "1×", "1.2×", "10×".
enum PlaybackSpeedPresentation {
    /// `rate` with up to two decimals and no trailing zeros, followed by "×".
    static func label(_ rate: Double, locale: Locale) -> String {
        L10n.string(
            "LabelPlaybackRate", rate.formatted(.number.precision(.fractionLength(0...2)).locale(locale)),
            locale: locale)
    }
}

/// The rate button in the full player's controls (D4): shows the rate and opens the speed sheet.
struct PlaybackSpeedButton: View {
    let model: PlayerViewModel
    @Binding var sheet: PlayerSheet?
    @Environment(\.locale) private var locale

    var body: some View {
        let label = PlaybackSpeedPresentation.label(model.rate, locale: locale)
        Button {
            sheet = .speed
        } label: {
            Text(verbatim: label)
                .font(.headline)
                .monospacedDigit()
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(verbatim: L10n.string("LabelPlaybackSpeed")))
        .accessibilityValue(Text(verbatim: label))
    }
}

/// The speed sheet (port of `PlaybackSpeedModal.vue`): the preset rates, with a checkmark on the
/// current one, and a stepper pinned below them. Choosing a preset applies it and closes the sheet;
/// each step applies and saves at once (D1, D3).
struct PlaybackSpeedSheet: View {
    let model: PlayerViewModel
    let close: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        let rate = model.rate
        List {
            ForEach(PlaybackSpeed.presets, id: \.self) { preset in
                PresetRow(
                    label: PlaybackSpeedPresentation.label(preset, locale: locale),
                    isCurrent: PlaybackSpeed.isSame(preset, rate)
                ) {
                    model.setRate(preset)
                    close()
                }
            }
        }
        // Pinned, as the legacy modal's stepper, so it stays visible at the medium detent.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SpeedStepper(model: model, rate: rate)
        }
        .playerSheetStyle(title: L10n.string("LabelPlaybackSpeed"), onDone: close)
    }
}

/// One preset rate.
private struct PresetRow: View {
    let label: String
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: ABSSpacing.small) {
                Text(verbatim: label)
                    .font(.body.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark")
                    .foregroundStyle(ABSColor.accent)
                    .opacity(isCurrent ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .fontWeight(isCurrent ? .semibold : nil)
        .listRowBackground(isCurrent ? ABSColor.accent.opacity(0.2) : nil)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// The − and + buttons with the rate between them, or, when that row is wider than the sheet (the
/// largest accessibility sizes on an iPhone), the rate above the buttons. VoiceOver reads the rate
/// as one adjustable element (swipe up or down to step); the buttons stay for Voice Control, Switch
/// Control, the keyboard and the pointer.
private struct SpeedStepper: View {
    let model: PlayerViewModel
    let rate: Double
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .title2) private var valueWidth = 88

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ABSSpacing.large) {
                stepButton(up: false)
                value
                stepButton(up: true)
            }
            VStack(spacing: ABSSpacing.small) {
                value
                HStack(spacing: ABSSpacing.large) {
                    stepButton(up: false)
                    stepButton(up: true)
                }
            }
        }
        .padding(.vertical, ABSSpacing.medium)
        .padding(.horizontal, ABSSpacing.large)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .background {
            // ⌘= for increase too: "+" is ⇧= on a US keyboard, so ⌘+ alone needs Shift.
            Button {
                model.stepRate(up: true)
            } label: {
                EmptyView()
            }
            .keyboardShortcut("=", modifiers: .command)
            .disabled(!model.canStepRate(up: true))
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    private var value: some View {
        let label = PlaybackSpeedPresentation.label(rate, locale: locale)
        return Text(verbatim: label)
            .font(.title2.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            // Capped so the scaled width alone can't push the row past the sheet.
            .frame(minWidth: min(valueWidth, 120))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: L10n.string("LabelPlaybackSpeed")))
            .accessibilityValue(Text(verbatim: label))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.stepRate(up: true)
                case .decrement: model.stepRate(up: false)
                @unknown default: break
                }
            }
    }

    private func stepButton(up: Bool) -> some View {
        Button {
            model.stepRate(up: up)
        } label: {
            Label {
                Text(verbatim: L10n.string(up ? "LabelIncreaseSpeed" : "LabelDecreaseSpeed"))
            } icon: {
                Image(systemName: up ? "plus" : "minus")
            }
            .labelStyle(.iconOnly)
            .font(.title3.weight(.semibold))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.bordered)
        .buttonRepeatBehavior(.enabled)
        // ⌘+ (with ⌘= in the stepper) and ⌘− on a hardware keyboard (iPad) and the Mac.
        .keyboardShortcut(up ? "+" : "-", modifiers: .command)
        .disabled(!model.canStepRate(up: up))
    }
}

#Preview("Button") {
    PlaybackSpeedButton(model: .preview(), sheet: .constant(nil))
}

#Preview("Sheet") {
    PlaybackSpeedSheet(model: .preview(), close: {})
}

#Preview("Sheet, off-preset rate") {
    let model = PlayerViewModel.preview()
    model.setRate(2.4)
    return PlaybackSpeedSheet(model: model, close: {})
}

#Preview("Sheet, at the maximum") {
    let model = PlayerViewModel.preview()
    model.setRate(PlaybackSpeed.range.upperBound)
    return PlaybackSpeedSheet(model: model, close: {})
}

#Preview("Sheet, accessibility size") {
    PlaybackSpeedSheet(model: .preview(), close: {})
        .dynamicTypeSize(.accessibility3)
}

#Preview("Sheet, largest accessibility size") {
    PlaybackSpeedSheet(model: .preview(), close: {})
        .dynamicTypeSize(.accessibility5)
}
