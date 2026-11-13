import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The mini player (port of the collapsed `components/app/AudioPlayer.vue`): the cover and title
/// open the full player, with play/pause, the jumps and a close button that stops playback. While
/// the player is locked (``PlayerDisplayOptions/isLocked``) the jumps go, as in legacy.
///
/// On iOS it is the tab view's bottom accessory; when the tab bar collapses it to the inline
/// placement only play/pause stays. At accessibility text sizes the cover, author and jumps go, so
/// the title, play/pause and close keep fitting. On macOS it is a bar under the content.
struct MiniPlayerView: View {
    let model: PlayerViewModel
    let router: Router
    @Environment(AppSettings.self) private var settings: AppSettings?
    #if os(iOS)
        @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    #endif
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var coverHeight: CGFloat = 40
    private var libraries = LibraryCoverSettings()

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

    private var layout: Layout {
        #if os(iOS)
            let isInline = placement == .inline
        #else
            let isInline = false
        #endif
        return .pick(isInline: isInline, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }

    var body: some View {
        HStack(spacing: 8) {
            openButton
            TransportControls(
                style: model.displayOptions.showsSkipControls ? layout.transportStyle : .playPauseOnly,
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
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            if layout.showsCloseAndProgress {
                MiniPlayerProgress(model: model)
            }
        }
    }

    private var openButton: some View {
        Button {
            router.isFullPlayerPresented = true
        } label: {
            HStack(spacing: 10) {
                if layout.showsCoverAndAuthor {
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
                    if layout.showsCoverAndAuthor, !model.author.isEmpty {
                        Text(verbatim: model.author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: L10n.string("LabelMiniPlayerAccessibility", model.title)))
        .accessibilityHint(Text(verbatim: L10n.string("LabelMiniPlayerHint")))
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
        .foregroundStyle(.secondary)
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

#Preview("Accessibility size") {
    MiniPlayerView(model: .preview(playing: true), router: Router())
        .frame(maxWidth: 375)
        .dynamicTypeSize(.accessibility3)
}
