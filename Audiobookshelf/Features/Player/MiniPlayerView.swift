import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The mini player (port of the collapsed `components/app/AudioPlayer.vue`): the cover and title
/// open the full player, and their context menu opens the scene's queue inspector, with
/// play/pause, the jumps and a close button that stops playback. While the player is locked
/// (``PlayerDisplayOptions/isLocked``) the jumps go, as in legacy.
///
/// On iOS it is the tab view's bottom accessory; when the tab bar collapses it to the inline
/// placement only play/pause stays. At accessibility text sizes the cover, author and jumps go, so
/// the title, on up to two lines, play/pause and close keep fitting. In a narrow window, such as
/// the iPhone Duo's, the jumps go, then the cover and author, so the title keeps a readable width
/// (#616). On iOS its text stops growing at ``largestTextSize``; a long press on the title or a
/// button shows it in the Large Content Viewer, as on the tab bar. On macOS it is a bar under the
/// content.
struct MiniPlayerView: View {
    let model: PlayerViewModel
    let router: Router
    #if os(iOS)
        @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    #endif
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// What the mini player shows for its placement and text size.
    enum Layout: Equatable {
        /// Cover, title and author, jumps and play/pause, close.
        case regular
        /// At accessibility text sizes: title, play/pause and close.
        case accessibility
        /// The inline accessory: title and play/pause.
        case inline

        static func pick(isInline: Bool, isAccessibilitySize: Bool) -> Layout {
            if isInline { return .inline }
            return isAccessibilitySize ? .accessibility : .regular
        }

        var transportStyle: TransportControls.Style { self == .regular ? .compact : .playPauseOnly }
        var showsCoverAndAuthor: Bool { self == .regular }
        var showsCloseAndProgress: Bool { self != .inline }
    }

    /// The largest text size the mini player shows. The system gives the bottom accessory a fixed
    /// height, which fits two lines of text (the title and author, or the title on two lines) up
    /// to this size; larger sizes, including the accessibility ones, keep it, as the tab bar keeps
    /// its own size.
    static let largestTextSize = DynamicTypeSize.xLarge

    private var layout: Layout {
        #if os(iOS)
            let isInline = placement == .inline
        #else
            let isInline = false
        #endif
        return .pick(isInline: isInline, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }

    var body: some View {
        // The layout comes from the text size the user picked; the bar's text stops growing.
        MiniPlayerBar(
            model: model, router: router, layout: layout,
            showsUpNextMenu: !dynamicTypeSize.isAccessibilitySize
        )
        #if os(iOS)
            .dynamicTypeSize(...Self.largestTextSize)
        #endif
    }

    /// The line shown, in place of the author, while recovery waits for the network.
    static let waitingForNetworkKey = "MessageNoNetworkConnection"
}

/// The mini player's content for ``MiniPlayerView/Layout``.
private struct MiniPlayerBar: View {
    let model: PlayerViewModel
    let router: Router
    let layout: MiniPlayerView.Layout
    /// Whether a long press on the title shows the Up Next menu. At accessibility text sizes the
    /// long press shows the Large Content Viewer instead (the two can't share it); Up Next stays
    /// in the full player and in the VoiceOver actions.
    let showsUpNextMenu: Bool
    @Environment(AppSettings.self) private var settings: AppSettings?
    @ScaledMetric(relativeTo: .body) private var coverHeight: CGFloat = 40
    /// The width the title keeps before the jumps, then the cover and author, give way to it:
    /// about a dozen characters.
    @ScaledMetric(relativeTo: .subheadline) private var readableTitleWidth: CGFloat = 110
    private var libraries = LibraryCoverSettings()

    init(model: PlayerViewModel, router: Router, layout: MiniPlayerView.Layout, showsUpNextMenu: Bool) {
        self.model = model
        self.router = router
        self.layout = layout
        self.showsUpNextMenu = showsUpNextMenu
    }

    var body: some View {
        // The first that fits with the title at its readable width; the last one otherwise.
        ViewThatFits(in: .horizontal) {
            if layout == .regular {
                row(showsJumps: model.displayOptions.showsSkipControls, showsCoverAndAuthor: true)
                if model.displayOptions.showsSkipControls {
                    row(showsJumps: false, showsCoverAndAuthor: true)
                }
            }
            row(showsJumps: false, showsCoverAndAuthor: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            if layout.showsCloseAndProgress {
                MiniPlayerProgress(model: model)
            }
        }
    }

    private func row(showsJumps: Bool, showsCoverAndAuthor: Bool) -> some View {
        HStack(spacing: 8) {
            openButton(showsCoverAndAuthor: showsCoverAndAuthor)
            TransportControls(
                style: showsJumps ? .compact : .playPauseOnly,
                showsPause: model.showsPause,
                isBuffering: model.isBuffering, jumpBackwardSeconds: model.jumpBackwardSeconds,
                jumpForwardSeconds: model.jumpForwardSeconds, haptic: settings?.hapticFeedback ?? .off
            ) { action in
                Task { await model.perform(action) }
            }
            if layout.showsCloseAndProgress {
                closeButton
            }
        }
    }

    private func openButton(showsCoverAndAuthor: Bool) -> some View {
        let showsWaiting = layout.showsCloseAndProgress && model.isWaitingForNetwork
        let showsAuthor = showsCoverAndAuthor && !model.author.isEmpty
        return Button {
            router.isFullPlayerPresented = true
        } label: {
            HStack(spacing: 10) {
                if showsCoverAndAuthor {
                    CoverView(
                        key: model.coverKey, title: model.title, author: model.author,
                        shape: model.coverShape(in: libraries),
                        accessibility: .hidden
                    )
                    .frame(height: coverHeight)
                    .clipShape(.rect(cornerRadius: 4))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: model.title)
                        .font(.subheadline.weight(.semibold))
                        // Two lines when nothing else needs the second (except inline, which is short).
                        .lineLimit(layout == .inline || showsWaiting || showsAuthor ? 1 : 2)
                    if showsWaiting {
                        // Recovery waits for the network (ADR 0007's "Waiting for network").
                        Text(verbatim: L10n.string(MiniPlayerView.waitingForNetworkKey))
                            .font(.caption)
                            .foregroundStyle(ABSColor.mutedForeground)
                            .lineLimit(1)
                    } else if showsAuthor {
                        Text(verbatim: model.author)
                            .font(.caption)
                            .foregroundStyle(ABSColor.mutedForeground)
                            .lineLimit(1)
                    }
                }
                // Asks for a readable width, so a narrower window drops the jumps, then the cover.
                .frame(idealWidth: readableTitleWidth, maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // The capped text size's stand-in (HIG): the title, large, on a long press.
        .accessibilityShowsLargeContentViewer {
            Text(verbatim: model.title)
        }
        .accessibilityLabel(Text(verbatim: L10n.string("LabelMiniPlayerAccessibility", model.title)))
        .accessibilityValue(
            Text(verbatim: model.isWaitingForNetwork ? L10n.string(MiniPlayerView.waitingForNetworkKey) : "")
        )
        .accessibilityHint(Text(verbatim: L10n.string("LabelMiniPlayerHint")))
        .accessibilityIdentifier("player.mini")
        .modifier(UpNextMenu(isEnabled: showsUpNextMenu, router: router))
        .accessibilityAction(named: Text(verbatim: L10n.string("HeaderUpNext"))) {
            router.isQueueInspectorPresented = true
        }
    }

    private var closeButton: some View {
        Button {
            model.close()
        } label: {
            Label {
                Text(verbatim: L10n.string("LabelClosePlayer"))
            } icon: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(ABSColor.mutedForeground)
        .accessibilityShowsLargeContentViewer {
            Label {
                Text(verbatim: L10n.string("LabelClosePlayer"))
            } icon: {
                Image(systemName: "xmark")
            }
        }
    }
}

/// The mini player's context menu, with Up Next, when `isEnabled`.
private struct UpNextMenu: ViewModifier {
    let isEnabled: Bool
    let router: Router

    func body(content: Content) -> some View {
        if isEnabled {
            content.contextMenu {
                Button {
                    router.isQueueInspectorPresented = true
                } label: {
                    Label {
                        Text(verbatim: L10n.string("HeaderUpNext"))
                    } icon: {
                        Image(systemName: "list.bullet")
                    }
                }
            }
        } else {
            content
        }
    }
}

/// A hairline of the progress under the mini player. Its own view, so playback ticks redraw only
/// it; VoiceOver hears the position in the full player.
private struct MiniPlayerProgress: View {
    let model: PlayerViewModel

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(ABSColor.accent)
                .frame(width: proxy.size.width * model.progress)
        }
        .frame(height: 2)
        .padding(.horizontal, 12)
        // Playback progress runs left to right in every language, like the full player's scrubber
        // (HIG: don't flip media playback controls or progress for right-to-left languages).
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }
}

extension PlayerViewModel {
    /// Runs a ``TransportControls`` command.
    func perform(_ action: TransportControls.Action) async {
        switch action {
        case .previousChapter: await previousChapter()
        case .jumpBackward: await jumpBackward()
        case .playPause: await togglePlayPause()
        case .jumpForward: await jumpForward()
        case .nextChapter: await nextChapter()
        }
    }

    /// The shape of the playing item's cover, the same in the mini and full players: square for a
    /// podcast episode, else the book covers of the item's library, or of the scene's current
    /// library when the item's isn't known (a restored item before its session starts).
    func coverShape(in libraries: LibraryCoverSettings) -> CoverShape {
        CoverShape(isPodcast: isPodcastEpisode, librarySettings: libraries.settings(forLibrary: libraryID))
    }
}

#Preview("Paused") {
    MiniPlayerView(model: .preview(), router: Router())
        .frame(maxWidth: 420)
}

#Preview("Buffering") {
    MiniPlayerView(model: .preview(playing: true, buffering: true), router: Router())
        .frame(maxWidth: 420)
}

#Preview("Narrow") {
    // About the iPhone Duo's accessory: the jumps and cover give way to the title.
    MiniPlayerView(model: .preview(playing: true), router: Router())
        .frame(maxWidth: 290)
}

#Preview("Accessibility size") {
    MiniPlayerView(model: .preview(playing: true), router: Router())
        .frame(maxWidth: 375)
        .dynamicTypeSize(.accessibility3)
}
