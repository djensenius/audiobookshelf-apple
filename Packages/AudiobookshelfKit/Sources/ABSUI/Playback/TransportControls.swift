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

    public var body: some View {
        HStack(spacing: style == .full ? 0 : 4) {
            switch style {
            case .full:
                chapterButton(.previousChapter)
                Spacer(minLength: 4)
                jumpButton(forward: false)
                Spacer(minLength: 4)
                playPauseButton
                Spacer(minLength: 4)
                jumpButton(forward: true)
                Spacer(minLength: 4)
                chapterButton(.nextChapter)
            case .compact:
                jumpButton(forward: false)
                playPauseButton
                jumpButton(forward: true)
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
            Image(systemName: Self.jumpSymbol(forward: forward, seconds: seconds))
                .font(iconFont)
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
            Image(systemName: next ? "forward.end.fill" : "backward.end.fill")
                .font(.title2)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .disabled(next ? !hasNextChapter : !hasPreviousChapter)
        .accessibilityLabel(Text(verbatim: L10n.string(next ? "LabelNextChapter" : "LabelPreviousChapter")))
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
