import SwiftUI

/// Clamps `progress` to `0...1`, treating non-finite values as `0`.
func clampedProgress(_ progress: Double) -> Double {
    progress.isFinite ? min(max(progress, 0), 1) : 0
}

/// The VoiceOver value for a progress fraction, for example "42%".
func progressAccessibilityValue(_ progress: Double, locale: Locale) -> String {
    clampedProgress(progress).formatted(.percent.precision(.fractionLength(0)).locale(locale))
}

/// A circular progress indicator, for example on download buttons and episode rows.
public struct ProgressRing: View {
    private let progress: Double
    private let tint: Color
    @ScaledMetric private var diameter: CGFloat
    @ScaledMetric private var lineWidth: CGFloat
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - progress: The fraction complete, `0...1`.
    ///   - diameter: The size at the default text size; it scales with Dynamic Type.
    public init(progress: Double, diameter: CGFloat = 24, lineWidth: CGFloat = 3, tint: Color = ABSColor.accent) {
        self.progress = clampedProgress(progress)
        self.tint = tint
        _diameter = ScaledMetric(wrappedValue: diameter, relativeTo: .body)
        _lineWidth = ScaledMetric(wrappedValue: lineWidth, relativeTo: .body)
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(ABSColor.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Self.animation(reduceMotion: reduceMotion), value: progress)
        }
        .padding(lineWidth / 2)
        .frame(width: diameter, height: diameter)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: L10n.string("LabelProgress")))
        .accessibilityValue(Text(verbatim: progressAccessibilityValue(progress, locale: locale)))
    }

    /// How the ring moves to a new value: animated, or at once with Reduce Motion.
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .default
    }
}

/// A thin progress bar along the bottom edge of a cover. Turns green when finished, like
/// legacy.
public struct ProgressBarOverlay: View {
    private let progress: Double
    private let isFinished: Bool
    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 4
    @Environment(\.locale) private var locale

    public init(progress: Double, isFinished: Bool = false) {
        self.progress = isFinished ? 1 : clampedProgress(progress)
        self.isFinished = isFinished
    }

    public var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(isFinished ? ABSColor.success : ABSColor.progress)
                .frame(width: proxy.size.width * progress)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: L10n.string(isFinished ? "LabelFinished" : "LabelProgress")))
        .accessibilityValue(Text(verbatim: isFinished ? "" : progressAccessibilityValue(progress, locale: locale)))
    }
}
