import ABSCore
import SwiftUI

/// One button of ``TransportToolbarItems``: what it does, shows and says. Built from the same
/// helpers as ``TransportControls``, so the toolbar and the full player's row can't drift apart.
struct TransportToolbarEntry: Equatable {
    let action: TransportControls.Action
    let symbol: String
    /// The interval under a plain jump arrow, such as "20s"; `nil` for other buttons.
    let caption: String?
    let accessibilityLabel: String
    let accessibilityValue: String
    let isEnabled: Bool
    /// Play/pause while buffering: a spinner instead of the symbol; it still works.
    let showsSpinner: Bool

    /// The buttons in order: previous chapter, jump back, play/pause, jump forward, next chapter.
    static func entries(
        showsPause: Bool, isBuffering: Bool, jumpBackwardSeconds: Int, jumpForwardSeconds: Int,
        hasPreviousChapter: Bool, hasNextChapter: Bool, locale: Locale
    ) -> [TransportToolbarEntry] {
        func chapter(next: Bool) -> TransportToolbarEntry {
            TransportToolbarEntry(
                action: next ? .nextChapter : .previousChapter, symbol: TransportControls.chapterSymbol(next: next),
                caption: nil, accessibilityLabel: TransportControls.chapterLabel(next: next), accessibilityValue: "",
                isEnabled: next ? hasNextChapter : hasPreviousChapter, showsSpinner: false)
        }
        func jump(forward: Bool) -> TransportToolbarEntry {
            let seconds = forward ? jumpForwardSeconds : jumpBackwardSeconds
            return TransportToolbarEntry(
                action: forward ? .jumpForward : .jumpBackward,
                symbol: TransportControls.jumpSymbol(forward: forward, seconds: seconds),
                caption: TransportControls.jumpCaption(seconds: seconds, locale: locale),
                accessibilityLabel: TransportControls.jumpLabel(forward: forward, seconds: seconds, locale: locale),
                accessibilityValue: "", isEnabled: true, showsSpinner: false)
        }
        let playPause = TransportToolbarEntry(
            action: .playPause, symbol: showsPause ? "pause.fill" : "play.fill", caption: nil,
            accessibilityLabel: TransportControls.playPauseLabel(showsPause: showsPause),
            accessibilityValue: TransportControls.playPauseAccessibilityValue(isBuffering: isBuffering),
            isEnabled: true, showsSpinner: isBuffering)
        return [chapter(next: false), jump(forward: false), playPause, jump(forward: true), chapter(next: true)]
    }
}

#if os(iOS)
    /// The transport as toolbar items (#84): the ``TransportControls`` row for the full player's
    /// toolbar when it's a vertical bar (the iPhone Duo's outer display). The items prefer the
    /// vertical bar and stay visible before other items; each tap plays the `haptic` impact.
    @available(iOS 27.1, *)
    public struct TransportToolbarItems: ToolbarContent {
        private let entries: [TransportToolbarEntry]
        private let haptic: HapticFeedback
        private let perform: (TransportControls.Action) -> Void

        /// The parameters are ``TransportControls``'s; `locale` formats the jump captions and labels.
        public init(
            showsPause: Bool, isBuffering: Bool = false, jumpBackwardSeconds: Int, jumpForwardSeconds: Int,
            hasPreviousChapter: Bool = false, hasNextChapter: Bool = false, haptic: HapticFeedback = .off,
            locale: Locale, perform: @escaping (TransportControls.Action) -> Void
        ) {
            entries = TransportToolbarEntry.entries(
                showsPause: showsPause, isBuffering: isBuffering, jumpBackwardSeconds: jumpBackwardSeconds,
                jumpForwardSeconds: jumpForwardSeconds, hasPreviousChapter: hasPreviousChapter,
                hasNextChapter: hasNextChapter, locale: locale)
            self.haptic = haptic
            self.perform = perform
        }

        public var body: some ToolbarContent {
            ToolbarItemGroup(placement: .bottomBar) {
                ForEach(entries, id: \.action) { entry in
                    TransportToolbarButton(entry: entry, haptic: haptic, perform: perform)
                }
            }
            .axisBehavior(.verticalPreferred)
            .visibilityPriority(.high)
        }
    }

    /// One toolbar transport button, with its own haptic trigger.
    private struct TransportToolbarButton: View {
        let entry: TransportToolbarEntry
        let haptic: HapticFeedback
        let perform: (TransportControls.Action) -> Void
        @State private var taps = 0

        var body: some View {
            Button {
                taps &+= 1
                perform(entry.action)
            } label: {
                Label {
                    Text(verbatim: entry.accessibilityLabel)
                } icon: {
                    VStack(spacing: 0) {
                        ZStack {
                            Image(systemName: entry.symbol)
                                .opacity(entry.showsSpinner ? 0 : 1)
                            if entry.showsSpinner {
                                ProgressView()
                            }
                        }
                        if let caption = entry.caption {
                            Text(verbatim: caption)
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
            }
            .disabled(!entry.isEnabled)
            .accessibilityLabel(Text(verbatim: entry.accessibilityLabel))
            .accessibilityValue(Text(verbatim: entry.accessibilityValue))
            .absHaptic(haptic, trigger: taps)
        }
    }
#endif
