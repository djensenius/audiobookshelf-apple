import ABSCore
import SwiftUI

/// A finished check or a progress ring, for rows. Nothing before the item is started.
public struct ProgressBadge: View {
    private let progress: ItemProgress?

    public init(progress: ItemProgress?) {
        self.progress = progress
    }

    public var body: some View {
        if let progress {
            if progress.isFinished {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(ABSColor.success)
                    .accessibilityLabel(Text(verbatim: L10n.string("LabelFinished")))
            } else if progress.isInProgress {
                ProgressRing(progress: progress.fraction, diameter: 20, lineWidth: 3, tint: ABSColor.progress)
            }
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
