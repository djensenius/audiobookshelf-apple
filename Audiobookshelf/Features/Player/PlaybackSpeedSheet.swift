import ABSAppModel
import ABSUI
import SwiftUI

/// The rate button in the full player's controls: for now the preset menu (the legacy speed modal's
/// rates). The speed sheet (P2-57b) replaces this file; its button sets `sheet = .speed`.
struct PlaybackSpeedButton: View {
    let model: PlayerViewModel
    @Binding var sheet: PlayerSheet?

    /// Legacy `PlaybackSpeedModal` rates.
    private static let rates: [Double] = [0.5, 1, 1.2, 1.5, 1.7, 2, 3]

    private static func label(_ rate: Double) -> String {
        L10n.string("LabelPlaybackRate", rate.formatted(.number.precision(.fractionLength(0...2))))
    }

    var body: some View {
        Menu {
            Picker(selection: Binding(get: { model.rate }, set: { model.setRate($0) })) {
                ForEach(Self.rates, id: \.self) { rate in
                    Text(verbatim: Self.label(rate)).tag(rate)
                }
            } label: {
                Text(verbatim: L10n.string("LabelPlaybackSpeed"))
            }
        } label: {
            Text(verbatim: Self.label(model.rate))
                .font(.headline)
                .monospacedDigit()
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(Text(verbatim: L10n.string("LabelPlaybackSpeed")))
        .accessibilityValue(Text(verbatim: Self.label(model.rate)))
    }
}

/// The speed sheet; a placeholder until P2-57b.
struct PlaybackSpeedSheet: View {
    let model: PlayerViewModel
    let close: () -> Void

    var body: some View {
        PlayerSheetPlaceholder(
            titleKey: "LabelPlaybackSpeed", systemImage: "gauge.with.dots.needle.67percent", close: close)
    }
}

#Preview("Button") {
    PlaybackSpeedButton(model: .preview(), sheet: .constant(nil))
}

#Preview("Sheet") {
    PlaybackSpeedSheet(model: .preview(), close: {})
}

#Preview("Sheet, accessibility size") {
    PlaybackSpeedSheet(model: .preview(), close: {})
        .dynamicTypeSize(.accessibility3)
}
