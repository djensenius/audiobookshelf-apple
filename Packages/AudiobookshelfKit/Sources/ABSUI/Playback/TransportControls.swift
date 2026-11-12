import ABSCore
import SwiftUI

/// The player's transport buttons: jump back, play/pause and jump forward, with previous and next
/// chapter around them in the full player (port of the legacy player's controls row).
///
/// It owns no state: values in, closures out. Each tap plays the `haptic` impact.
public struct TransportControls: View {
    /// How much the controls show.
    public enum Style: Sendable, Hashable {
        /// Jumps and play/pause at full size, between previous and next chapter.
        case full
        /// Small jumps and play/pause, for the mini player.
        case compact
        /// Only play/pause, for the smallest mini player.
        case playPauseOnly
    }

    /// One transport command.
    public enum Action: Sendable, Hashable {
        case previousChapter, jumpBackward, playPause, jumpForward, nextChapter
    }

    private let style: Style
    private let showsPause: Bool
    private let isBuffering: Bool
    private let jumpBackwardSeconds: Int
    private let jumpForwardSeconds: Int
    private let hasPreviousChapter: Bool
    private let hasNextChapter: Bool
    private let haptic: HapticFeedback
    private let perform: (Action) -> Void
    @State private var taps = 0
    @Environment(\.locale) private var locale

    /// - Parameters:
    ///   - showsPause: Whether play/pause shows pause (play is requested).
    ///   - isBuffering: Shows a spinner in the play/pause button; it still works.
    ///   - hasPreviousChapter, hasNextChapter: Enable the chapter buttons (``Style/full`` only).
    ///   - haptic: The impact each tap plays; `.off` for none.
    ///   - perform: Called with the tapped command.
    public init(
        style: Style, showsPause: Bool, isBuffering: Bool = false, jumpBackwardSeconds: Int, jumpForwardSeconds: Int,
        hasPreviousChapter: Bool = false, hasNextChapter: Bool = false, haptic: HapticFeedback = .off,
        perform: @escaping (Action) -> Void
    ) {
        self.style = style
        self.showsPause = showsPause
        self.isBuffering = isBuffering
        self.jumpBackwardSeconds = jumpBackwardSeconds
        self.jumpForwardSeconds = jumpForwardSeconds
        self.hasPreviousChapter = hasPreviousChapter
        self.hasNextChapter = hasNextChapter
        self.haptic = haptic
        self.perform = perform
    }

    /// Intervals with a numbered `gobackward.N` / `goforward.N` SF Symbol.
    nonisolated static let numberedJumpSymbols: Set<Int> = [5, 10, 15, 30, 45, 60, 75, 90]

    /// The jump button's symbol: numbered when SF Symbols has one for `seconds`, else plain.
    nonisolated static func jumpSymbol(forward: Bool, seconds: Int) -> String {
        let base = forward ? "goforward" : "gobackward"
        return numberedJumpSymbols.contains(seconds) ? "\(base).\(seconds)" : base
    }

    /// The interval shown under a jump button's plain arrow, for example "2m" or "20s", like the
    /// legacy full player's `getJumpLabel` (minutes from 120 seconds); `nil` when the symbol is
    /// numbered and already shows it.
    nonisolated static func jumpCaption(seconds: Int, locale: Locale) -> String? {
        guard !numberedJumpSymbols.contains(seconds) else { return nil }
        let minutes = seconds >= 120
        let value = minutes ? Double(seconds) / 60 : Double(seconds)
        return L10n.string(
            minutes ? "UnitMinutesShort" : "UnitSecondsShort", value.formatted(.number.locale(locale)),
            locale: locale)
    }

    /// The VoiceOver label of a jump button, for example "Jump forward 30 seconds".
    nonisolated static func jumpLabel(forward: Bool, seconds: Int, locale: Locale) -> String {
        let interval = DurationStyle.timestamp.accessibilityString(Double(seconds), locale: locale)
        return L10n.string(forward ? "LabelJumpForwardBy" : "LabelJumpBackwardBy", interval)
    }

    /// The play/pause button's VoiceOver label.
    nonisolated static func playPauseLabel(showsPause: Bool) -> String {
        L10n.string(showsPause ? "ButtonPause" : "ButtonPlay")
    }

    /// The play/pause button's VoiceOver value: "Loading..." while buffering, else empty.
    nonisolated static func playPauseAccessibilityValue(isBuffering: Bool) -> String {
        isBuffering ? L10n.string("MessageLoading") : ""
    }

    /// The previous or next chapter button's symbol.
    nonisolated static func chapterSymbol(next: Bool) -> String {
        next ? "forward.end.fill" : "backward.end.fill"
    }

    /// The previous or next chapter button's VoiceOver label.
    nonisolated static func chapterLabel(next: Bool) -> String {
        L10n.string(next ? "LabelNextChapter" : "LabelPreviousChapter")
    }

    public var body: some View {
        Group {
            switch style {
            case .full:
                // One row when it fits; otherwise (accessibility text sizes on a narrow screen) the
                // jumps and play/pause, with the chapter buttons on a second row, so every action
                // stays reachable.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        chapterButton(.previousChapter)
                        Spacer(minLength: 4)
                        jumpButton(forward: false)
                        Spacer(minLength: 4)
                        playPauseButton
                        Spacer(minLength: 4)
                        jumpButton(forward: true)
                        Spacer(minLength: 4)
                        chapterButton(.nextChapter)
                    }
                    VStack(spacing: 8) {
                        HStack(spacing: 4) {
                            jumpButton(forward: false)
                            Spacer(minLength: 4)
                            playPauseButton
                            Spacer(minLength: 4)
                            jumpButton(forward: true)
                        }
                        HStack(spacing: 4) {
                            chapterButton(.previousChapter)
                            Spacer(minLength: 4)
                            chapterButton(.nextChapter)
                        }
                    }
                }
            case .compact:
                HStack(spacing: 4) {
                    jumpButton(forward: false)
                    playPauseButton
                    jumpButton(forward: true)
                }
            case .playPauseOnly:
                playPauseButton
            }
        }
        // Like the scrubber, media playback controls aren't mirrored in right-to-left languages
        // (Human Interface Guidelines, Right to left): back stays on the left and forward on the
        // right, matching the time direction.
        .environment(\.layoutDirection, .leftToRight)
        .buttonStyle(.borderless)
        .absHaptic(haptic, trigger: taps)
    }

    private var iconFont: Font { style == .full ? .title : .title3 }

    private func tap(_ action: Action) {
        taps &+= 1
        perform(action)
    }

    private var playPauseButton: some View {
        Button {
            tap(.playPause)
        } label: {
            ZStack {
                Image(systemName: showsPause ? "pause.fill" : "play.fill")
                    .opacity(isBuffering ? 0 : 1)
                if isBuffering {
                    ProgressView()
                        .controlSize(style == .full ? .large : .regular)
                }
            }
            .font(style == .full ? .largeTitle : .title2)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
        .accessibilityLabel(Text(verbatim: Self.playPauseLabel(showsPause: showsPause)))
        .accessibilityValue(Text(verbatim: Self.playPauseAccessibilityValue(isBuffering: isBuffering)))
    }

    private func jumpButton(forward: Bool) -> some View {
        let seconds = forward ? jumpForwardSeconds : jumpBackwardSeconds
        return Button {
            tap(forward ? .jumpForward : .jumpBackward)
        } label: {
            VStack(spacing: 0) {
                Image(systemName: Self.jumpSymbol(forward: forward, seconds: seconds))
                    .font(iconFont)
                if let caption = Self.jumpCaption(seconds: seconds, locale: locale) {
                    Text(verbatim: caption)
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
        .accessibilityLabel(Text(verbatim: Self.jumpLabel(forward: forward, seconds: seconds, locale: locale)))
    }

    private func chapterButton(_ action: Action) -> some View {
        let next = action == .nextChapter
        return Button {
            tap(action)
        } label: {
            Image(systemName: Self.chapterSymbol(next: next))
                .font(.title2)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .disabled(next ? !hasNextChapter : !hasPreviousChapter)
        .accessibilityLabel(Text(verbatim: Self.chapterLabel(next: next)))
    }
}

#Preview {
    VStack(spacing: 24) {
        TransportControls(
            style: .full, showsPause: true, jumpBackwardSeconds: 10, jumpForwardSeconds: 30, hasPreviousChapter: true,
            hasNextChapter: false
        ) { _ in }
        TransportControls(
            style: .compact, showsPause: false, isBuffering: true, jumpBackwardSeconds: 10,
            jumpForwardSeconds: 30
        ) { _ in }
        TransportControls(style: .playPauseOnly, showsPause: false, jumpBackwardSeconds: 10, jumpForwardSeconds: 30) {
            _ in
        }
    }
    .padding()
}

#Preview("Right to left") {
    TransportControls(
        style: .full, showsPause: true, jumpBackwardSeconds: 10, jumpForwardSeconds: 30, hasPreviousChapter: true,
        hasNextChapter: true
    ) { _ in }
    .padding()
    .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Accessibility size, narrow") {
    TransportControls(
        style: .full, showsPause: true, jumpBackwardSeconds: 10, jumpForwardSeconds: 300, hasPreviousChapter: true,
        hasNextChapter: true
    ) { _ in }
    .frame(width: 320)
    .padding()
    .dynamicTypeSize(.accessibility3)
}
