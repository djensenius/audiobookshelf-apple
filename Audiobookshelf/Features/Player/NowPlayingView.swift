import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The full player (port of the expanded `components/app/AudioPlayer.vue`): the cover, title,
/// author and chapter, the scrubber with its chapter-track toggle, the transport controls, the
/// speed control and the AirPlay picker, with ``PlayerActionsBar`` in the bottom toolbar. It
/// presents one ``PlayerSheet`` at a time, per window.
///
/// iOS presents it as a full-screen cover on every size (ADR 0004); ``PlayerSlot`` closes it
/// when playback closes.
///
/// Everything that follows the playback time (the scrubber, the titles' chapter and the transport's
/// next-chapter state) lives in child views, so a playback tick doesn't re-render the cover, the
/// menus or the AirPlay picker.
struct NowPlayingView: View {
    let model: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: PlayerSheet?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    cover
                    NowPlayingTitles(model: model)
                    NowPlayingScrubber(model: model)
                    NowPlayingTransport(model: model)
                    secondaryControls
                }
                .padding(.horizontal, 24)
                .padding(.vertical)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label {
                            Text(verbatim: L10n.string("LabelMinimizePlayer"))
                        } icon: {
                            Image(systemName: "chevron.down")
                        }
                        .labelStyle(.iconOnly)
                    }
                }
                PlayerActionsBar(model: model, sheet: $sheet)
            }
        }
        .sheet(item: $sheet) { sheet in
            PlayerSheetContent(sheet: sheet, model: model) { self.sheet = nil }
        }
    }

    private var cover: some View {
        CoverView(
            key: model.coverKey, title: model.title, author: model.author, shape: model.coverShape
        )
        .clipShape(.rect(cornerRadius: 8))
        .shadow(radius: 8, y: 4)
        .containerRelativeFrame(.vertical) { height, _ in height * 0.45 }
        .accessibilityHidden(true)
    }

    private var secondaryControls: some View {
        HStack {
            Toggle(isOn: Binding(get: { model.usesChapterTrack }, set: { _ in model.toggleChapterTrack() })) {
                Label {
                    Text(verbatim: L10n.string("LabelChapterTrack"))
                } icon: {
                    Image(systemName: "list.bullet.indent")
                }
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
            }
            .toggleStyle(.button)
            Spacer()
            PlaybackSpeedButton(model: model, sheet: $sheet)
            Spacer()
            RoutePicker(player: nil)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
    }
}

/// The chapter, title and author. Its own view: the chapter title can follow the playback time.
private struct NowPlayingTitles: View {
    let model: PlayerViewModel

    var body: some View {
        VStack(spacing: 4) {
            if let chapter = model.chapterTitle {
                Text(verbatim: chapter)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: model.title)
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            if !model.author.isEmpty {
                Text(verbatim: model.author)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(3)
    }
}

/// The scrubber, redrawn on every playback tick. Swipe up and down jump by the skip intervals.
///
/// The view model is shared by every window, so each scrubber scrubs as its own
/// ``PlayerViewModel/ScrubOwner``: a drag in another window can't move or end this one's scrub.
/// If it disappears mid-drag (the cover closed, so the drag never reported its end), it cancels
/// its own scrub without seeking.
private struct NowPlayingScrubber: View {
    let model: PlayerViewModel
    @State private var owner = PlayerViewModel.ScrubOwner()

    var body: some View {
        PlayerScrubber(
            progress: model.progress, elapsed: model.elapsed, remaining: model.remainingAtRate,
            onScrub: { model.scrub(to: $0, owner: owner) },
            onScrubEnd: {
                // Finish now, so disappearing before the seek task runs can't cancel it.
                guard let seek = model.finishScrub(owner: owner) else { return }
                Task { await model.commitScrub(seek) }
            },
            onIncrement: { Task { await model.jumpForward() } },
            onDecrement: { Task { await model.jumpBackward() } }
        )
        .onDisappear { model.cancelScrub(owner: owner) }
    }
}

/// The transport controls. Their own view: the next-chapter state reads the playback time.
private struct NowPlayingTransport: View {
    let model: PlayerViewModel
    @Environment(AppSettings.self) private var settings: AppSettings?

    var body: some View {
        TransportControls(
            style: .full, showsPause: model.showsPause, isBuffering: model.isBuffering,
            jumpBackwardSeconds: model.jumpBackwardSeconds, jumpForwardSeconds: model.jumpForwardSeconds,
            hasPreviousChapter: model.hasPreviousChapter, hasNextChapter: model.hasNextChapter,
            haptic: settings?.hapticFeedback ?? .off
        ) { action in
            Task { await model.perform(action) }
        }
    }
}

#Preview("Paused") {
    NowPlayingView(model: .preview())
}

#Preview("Playing") {
    NowPlayingView(model: .preview(at: 9_500, playing: true))
}

#Preview("Accessibility size") {
    NowPlayingView(model: .preview(at: 9_500, playing: true))
        .dynamicTypeSize(.accessibility3)
}
