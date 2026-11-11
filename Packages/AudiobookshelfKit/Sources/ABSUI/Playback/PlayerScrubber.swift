import SwiftUI

/// The player's position slider (port of the legacy player's track bar), with the elapsed time
/// under its leading end and the remaining time under its trailing end.
///
/// It owns no state: it shows `progress` and reports drags as fractions of the track through
/// `onScrub`, then `onScrubEnd` when the drag ends, so the caller decides when to seek. A drag
/// the system cancels (a scroll view taking the pan, Control Center, a call, the app going to the
/// background) ends it too: the dragging flag is gesture state, which resets on cancellation, and
/// its reset calls `onScrubEnd`, which is why that isn't driven by `onEnded` (skipped on cancel).
///
/// VoiceOver reads it as one adjustable element: the elapsed and remaining times as its value,
/// with swipe up and down calling `onIncrement` and `onDecrement` (the caller's jump forward and
/// back).
public struct PlayerScrubber: View {
    private let progress: Double
    private let elapsed: Double
    private let remaining: Double
    private let onScrub: (Double) -> Void
    private let onScrubEnd: () -> Void
    private let onIncrement: () -> Void
    private let onDecrement: () -> Void
    @GestureState private var isDragging = false
    @ScaledMetric(relativeTo: .caption) private var trackHeight: CGFloat = 6
    @ScaledMetric(relativeTo: .caption) private var thumbDiameter: CGFloat = 14
    @Environment(\.locale) private var locale
    @Environment(\.isEnabled) private var isEnabled

    /// - Parameters:
    ///   - progress: The fraction played, `0...1`.
    ///   - elapsed: Seconds played, shown as a timestamp.
    ///   - remaining: Seconds left, shown as a negative timestamp.
    ///   - onScrub: Called with the fraction under the finger, `0...1`, while dragging.
    ///   - onScrubEnd: Called once when a drag ends or is cancelled.
    ///   - onIncrement: VoiceOver's increment (swipe up).
    ///   - onDecrement: VoiceOver's decrement (swipe down).
    public init(
        progress: Double, elapsed: Double, remaining: Double, onScrub: @escaping (Double) -> Void,
        onScrubEnd: @escaping () -> Void, onIncrement: @escaping () -> Void, onDecrement: @escaping () -> Void
    ) {
        self.progress = clampedProgress(progress)
        self.elapsed = elapsed
        self.remaining = remaining
        self.onScrub = onScrub
        self.onScrubEnd = onScrubEnd
        self.onIncrement = onIncrement
        self.onDecrement = onDecrement
    }

    /// The visible remaining time: the timestamp with a leading minus, like legacy.
    nonisolated static func remainingText(_ seconds: Double, locale: Locale) -> String {
        "-" + DurationStyle.timestamp.string(seconds, locale: locale)
    }

    /// The VoiceOver value, for example "4 minutes, 5 seconds, 1 hour remaining".
    nonisolated static func accessibilityValue(elapsed: Double, remaining: Double, locale: Locale) -> String {
        [
            DurationStyle.timestamp.accessibilityString(elapsed, locale: locale),
            L10n.string("LabelTimeRemaining", DurationStyle.timestamp.accessibilityString(remaining, locale: locale)),
        ]
        .joined(separator: ", ")
    }

    /// The fraction of a track `width` points wide under `x`, clamped to `0...1`.
    nonisolated static func fraction(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0, x.isFinite else { return 0 }
        return Double(min(max(x / width, 0), 1))
    }

    /// Reacts to the dragging flag changing: a drag that stops, by ending or by being cancelled,
    /// ends the scrub. Starting needs nothing: the first `onScrub` begins it.
    func draggingChanged(from wasDragging: Bool, to isDragging: Bool) {
        if wasDragging, !isDragging { onScrubEnd() }
    }

    /// Performs VoiceOver's adjustable action: up and down jump by the caller's skip intervals.
    func adjust(_ direction: AccessibilityAdjustmentDirection) {
        switch direction {
        case .increment: onIncrement()
        case .decrement: onDecrement()
        @unknown default: break
        }
    }

    public var body: some View {
        VStack(spacing: 6) {
            track
            HStack {
                Text(verbatim: DurationStyle.timestamp.string(elapsed, locale: locale))
                Spacer(minLength: 8)
                Text(verbatim: Self.remainingText(remaining, locale: locale))
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: L10n.string("LabelProgress")))
        .accessibilityValue(
            Text(verbatim: Self.accessibilityValue(elapsed: elapsed, remaining: remaining, locale: locale))
        )
        .accessibilityAdjustableAction { adjust($0) }
    }

    private var track: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(ABSColor.track)
                    .frame(height: trackHeight)
                Capsule()
                    .fill(isEnabled ? ABSColor.accent : Color.secondary)
                    .frame(width: width * progress, height: trackHeight)
                Circle()
                    .fill(isEnabled ? ABSColor.accent : Color.secondary)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .scaleEffect(isDragging ? 1.4 : 1)
                    .offset(x: width * progress - thumbDiameter / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, dragging, _ in dragging = true }
                    .onChanged { value in
                        onScrub(Self.fraction(atX: value.location.x, width: width))
                    }
            )
        }
        // At least a 44-point touch target, growing with the thumb at large text sizes.
        .frame(height: max(44, thumbDiameter * 2))
        .contentShape(.rect)
        .animation(.snappy, value: isDragging)
        .onChange(of: isDragging) { wasDragging, dragging in
            draggingChanged(from: wasDragging, to: dragging)
        }
    }
}

#Preview {
    PlayerScrubber(
        progress: 0.35, elapsed: 245, remaining: 3_600, onScrub: { _ in }, onScrubEnd: {}, onIncrement: {},
        onDecrement: {}
    )
    .padding()
}
