import SwiftUI

/// The whole item's progress, shown above the chapter's ``PlayerScrubber`` when the player shows
/// both (port of the legacy player's total track): a thin bar with the elapsed time under its
/// leading end and the remaining time under its trailing end. It's read-only: seeking is the
/// chapter scrubber's job.
///
/// VoiceOver reads it as one element labelled "Total Track", with the times as its value.
public struct PlayerTotalTrack: View {
    private let progress: Double
    private let elapsed: Double
    private let remaining: Double
    @ScaledMetric(relativeTo: .caption2) private var trackHeight: CGFloat = 4
    @Environment(\.locale) private var locale

    /// - Parameters:
    ///   - progress: The fraction of the item played, `0...1`.
    ///   - elapsed: Seconds played, shown as a timestamp.
    ///   - remaining: Seconds left, shown as a negative timestamp.
    public init(progress: Double, elapsed: Double, remaining: Double) {
        self.progress = clampedProgress(progress)
        self.elapsed = elapsed
        self.remaining = remaining
    }

    public var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(verbatim: DurationStyle.timestamp.string(elapsed, locale: locale))
                Spacer(minLength: 8)
                Text(verbatim: PlayerScrubber.remainingText(remaining, locale: locale))
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(ABSColor.track)
                    Capsule()
                        .fill(Color.secondary)
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: trackHeight)
        }
        // Not mirrored in right-to-left languages, like ``PlayerScrubber``.
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: L10n.string("LabelTotalTrack")))
        .accessibilityValue(
            Text(verbatim: PlayerScrubber.accessibilityValue(elapsed: elapsed, remaining: remaining, locale: locale))
        )
    }
}

#Preview {
    VStack(spacing: 16) {
        PlayerTotalTrack(progress: 0.6, elapsed: 8_400, remaining: 5_600)
        PlayerScrubber(
            progress: 0.35, elapsed: 245, remaining: 455, onScrub: { _ in }, onScrubEnd: {}, onIncrement: {},
            onDecrement: {})
    }
    .padding()
}
