import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The mini player (port of the collapsed `components/app/AudioPlayer.vue`): the cover and title
/// open the full player, with play/pause, the jumps and a close button that stops playback.
///
/// On iOS it is the tab view's bottom accessory; when the tab bar collapses it to the inline
/// placement only play/pause stays. On macOS it is a bar under the content.
struct MiniPlayerView: View {
    let model: PlayerViewModel
    let router: Router
    @Environment(AppSettings.self) private var settings: AppSettings?
    #if os(iOS)
        @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    #endif
    @ScaledMetric(relativeTo: .body) private var coverHeight: CGFloat = 40

    private var isInline: Bool {
        #if os(iOS)
            placement == .inline
        #else
            false
        #endif
    }

    var body: some View {
        HStack(spacing: 8) {
            openButton
            TransportControls(
                style: isInline ? .playPauseOnly : .compact, showsPause: model.showsPause,
                isBuffering: model.isBuffering, jumpBackwardSeconds: model.jumpBackwardSeconds,
                jumpForwardSeconds: model.jumpForwardSeconds, haptic: settings?.hapticFeedback ?? .off
            ) { action in
                Task { await model.perform(action) }
            }
            if !isInline {
                closeButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            if !isInline {
                MiniPlayerProgress(model: model)
            }
        }
    }

    private var openButton: some View {
        Button {
            router.isFullPlayerPresented = true
        } label: {
            HStack(spacing: 10) {
                if !isInline {
                    CoverView(
                        key: model.coverKey, title: model.title, author: model.author, shape: model.coverShape,
                        accessibility: .hidden
                    )
                    .frame(height: coverHeight)
                    .clipShape(.rect(cornerRadius: 4))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: model.title)
                        .font(.subheadline.weight(.semibold))
                    if !isInline, !model.author.isEmpty {
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
        #if os(iOS)
            // TODO(#183): the hint on macOS too, once the Now Playing window opens.
            .accessibilityHint(Text(verbatim: L10n.string("LabelMiniPlayerHint")))
        #endif
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

    /// The shape of the playing item's cover, the same in the mini and full players.
    var coverShape: CoverShape { Self.coverShape(isPodcastEpisode: isPodcastEpisode) }

    /// Square artwork for a podcast episode, else a book cover.
    nonisolated static func coverShape(isPodcastEpisode: Bool) -> CoverShape {
        isPodcastEpisode ? .square : .book
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
