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
/// From iOS 27.1 it follows the display (#84, ``PlayerLayout``): a split with the details on a
/// regular display, the controls on the bottom half in laptop pose, and the transport in the
/// toolbar's vertical bar. Before that and on macOS it's always the column.
///
/// Everything that follows the playback time (the scrubber, the titles' chapter and the transport's
/// next-chapter state) lives in child views, so a playback tick doesn't re-render the cover, the
/// menus or the AirPlay picker.
struct NowPlayingView: View {
    let model: PlayerViewModel
    /// The layout to use instead of reading it from the display, for previews.
    private let forcedLayout: PlayerLayout?
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: PlayerSheet?
    /// The details pane's tab, here so it survives arrangement changes.
    @State private var detailsTab = PlayerDetailsTab.chapters
    /// Whether the split arrangement is side by side, showing the details pane.
    @State private var isSplit = false
    /// The details pane's bookmark form, presented from here so an edit survives the pane going
    /// away when the arrangement changes.
    @State private var bookmarkEditor: BookmarkEditorTarget?
    private var libraries = LibraryCoverSettings()

    init(model: PlayerViewModel, forcedLayout: PlayerLayout? = nil) {
        self.model = model
        self.forcedLayout = forcedLayout
    }

    var body: some View {
        NavigationStack {
            PlayerLayoutReader(forcedLayout: forcedLayout) { layout in
                actionsToolbar(content(layout), layout: layout)
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
                    }
            }
            .bookmarkEditor(model: model, target: $bookmarkEditor)
        }
        .sheet(item: $sheet) { sheet in
            PlayerSheetContent(sheet: sheet, model: model) { self.sheet = nil }
        }
    }

    @ViewBuilder
    private func content(_ layout: PlayerLayout) -> some View {
        #if os(iOS)
            if #available(iOS 27.1, *) {
                if layout.arrangement == .column {
                    column(layout)
                } else {
                    PlayerArrangement(arrangement: layout.arrangement, isSplit: $isSplit) {
                        artwork
                    } titles: {
                        NowPlayingTitles(model: model)
                    } controls: {
                        NowPlayingScrubber(model: model)
                        NowPlayingTransport(model: model)
                        secondaryControls
                    } details: {
                        PlayerDetailsPane(model: model, tab: $detailsTab, bookmarkEditor: $bookmarkEditor)
                    } backdrop: {
                        PlayerBackdrop(model: model, shape: model.coverShape(in: libraries))
                    }
                }
            } else {
                column(layout)
            }
        #else
            column(layout)
        #endif
    }

    /// The column layout. With the transport in the toolbar's vertical bar, the column leaves it
    /// out. From iOS 27.1 the artwork extends behind it as a backdrop.
    @ViewBuilder
    private func column(_ layout: PlayerLayout) -> some View {
        #if os(iOS)
            if #available(iOS 27.1, *) {
                columnStack(layout)
                    .background { PlayerBackdrop(model: model, shape: model.coverShape(in: libraries)) }
            } else {
                columnStack(layout)
            }
        #else
            columnStack(layout)
        #endif
    }

    private func columnStack(_ layout: PlayerLayout) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                artwork
                    .containerRelativeFrame(.vertical) { height, _ in height * 0.45 }
                NowPlayingTitles(model: model)
                NowPlayingScrubber(model: model)
                if !layout.transportInToolbar {
                    NowPlayingTransport(model: model)
                }
                secondaryControls
            }
            .padding(.horizontal, 24)
            .padding(.vertical)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// ``PlayerActionsBar`` in the bottom toolbar, without chapters and bookmarks while the
    /// details pane shows them, or, with the transport in the toolbar's vertical bar,
    /// ``PlayerVerticalToolbar``.
    @ViewBuilder
    private func actionsToolbar(_ content: some View, layout: PlayerLayout) -> some View {
        #if os(iOS)
            if #available(iOS 27.1, *) {
                if layout.transportInToolbar {
                    content.toolbar { PlayerVerticalToolbar(model: model, sheet: $sheet) }
                } else {
                    content.toolbar {
                        PlayerActionsBar(
                            model: model, sheet: $sheet,
                            showsDetailSlots: !(layout.arrangement == .split && isSplit))
                    }
                }
            } else {
                content.toolbar { PlayerActionsBar(model: model, sheet: $sheet) }
            }
        #else
            content.toolbar { PlayerActionsBar(model: model, sheet: $sheet) }
        #endif
    }

    /// The cover, at the size of its frame.
    private var artwork: some View {
        CoverView(
            key: model.coverKey, title: model.title, author: model.author, shape: model.coverShape(in: libraries)
        )
        .clipShape(.rect(cornerRadius: 8))
        .shadow(radius: 8, y: 4)
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

/// Reads the full player's ``PlayerLayout`` from the size classes, the display's fold and the
/// toolbar's vertical bar (iOS 27.1 and later); before that and on macOS, the fallback column.
private struct PlayerLayoutReader<Content: View>: View {
    let forcedLayout: PlayerLayout?
    @ViewBuilder let content: (PlayerLayout) -> Content

    var body: some View {
        if let forcedLayout {
            content(forcedLayout)
        } else {
            #if os(iOS)
                if #available(iOS 27.1, *) {
                    DisplayLayoutReader(content: content)
                } else {
                    content(.fallback)
                }
            #else
                content(.fallback)
            #endif
        }
    }
}

#if os(iOS)
    @available(iOS 27.1, *)
    private struct DisplayLayoutReader<Content: View>: View {
        @ViewBuilder let content: (PlayerLayout) -> Content
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
        @Environment(\.verticalSizeClass) private var verticalSizeClass
        @Environment(\.toolbarVerticalEdge) private var toolbarVerticalEdge
        /// `nil` until the first geometry arrives.
        @State private var fold: PlayerFold?

        var body: some View {
            let layout = PlayerLayout.resolve(
                supportsArrangements: true, regularWidth: horizontalSizeClass == .regular,
                regularHeight: verticalSizeClass == .regular, fold: fold, verticalToolbar: toolbarVerticalEdge != nil)
            content(layout)
                .onGeometryChange(for: PlayerFold.self) { proxy in
                    PlayerFold(divisions: proxy.reservedRegions(kind: .division).map { ($0.frame, $0.isActive) })
                } action: {
                    fold = $0
                }
        }
    }
#endif

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
