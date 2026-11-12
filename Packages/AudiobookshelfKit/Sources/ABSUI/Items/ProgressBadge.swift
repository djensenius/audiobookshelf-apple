import ABSCore
import SwiftUI

/// A finished check or a progress ring, for rows. Nothing before the item is started. One
/// VoiceOver element, "Progress" with the value "Finished" or "42%"; the shapes differ, not only
/// the colours.
public struct ProgressBadge: View {
    private let progress: ItemProgress?
    @Environment(\.locale) private var locale

    public init(progress: ItemProgress?) {
        self.progress = progress
    }

    public var body: some View {
        if let progress, let value = ItemPresentation.progressBadgeValue(progress, locale: locale) {
            Group {
                if progress.isFinished {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ABSColor.success)
                } else {
                    // The ring's diameter is a `@ScaledMetric`, so it grows with Dynamic Type.
                    ProgressRing(progress: progress.fraction, diameter: 20, lineWidth: 3, tint: ABSColor.progress)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: L10n.string("LabelProgress")))
            .accessibilityValue(Text(verbatim: value))
            // The finished check is an `Image`; like `MediaBadge`, it is a value, not a picture.
            .accessibilityRemoveTraits(.isImage)
        }
    }
}

#Preview("Progress badges") {
    HStack(spacing: ABSSpacing.large) {
        ProgressBadge(progress: ItemProgress(fraction: 1, isFinished: true))
        ProgressBadge(progress: ItemProgress(fraction: 0.4))
        ProgressBadge(progress: nil)
    }
    .padding()
    .absBackground()
}
