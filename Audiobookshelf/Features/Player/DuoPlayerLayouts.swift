#if os(iOS)
    import ABSAppModel
    import ABSCore
    import ABSUI
    import SwiftUI

    /// The full player's arrangements on large and folding displays (#84), picked by
    /// ``PlayerLayout``: ``PlayerLayout/Arrangement/split`` and ``PlayerLayout/Arrangement/tabletop``.
    /// The column layout stays in ``NowPlayingView``.
    @available(iOS 27.1, *)
    struct PlayerArrangement<Artwork: View, Titles: View, Controls: View, Details: View, Backdrop: View>: View {
        let arrangement: PlayerLayout.Arrangement
        /// Set to whether the split is side by side, from the primary pane's `splitArrangementAxis`.
        @Binding var isSplit: Bool
        @ViewBuilder let artwork: Artwork
        @ViewBuilder let titles: Titles
        @ViewBuilder let controls: Controls
        @ViewBuilder let details: Details
        /// ``PlayerBackdrop``, behind the panes that show the artwork.
        @ViewBuilder let backdrop: Backdrop

        var body: some View {
            if arrangement == .tabletop {
                tabletop
            } else {
                split
            }
        }

        /// The cover, titles and controls as primary, the details as secondary, half and half,
        /// side by side only when wider than tall (ADR 0004). Otherwise, as on an iPad in portrait,
        /// the primary fills it and the details open as sheets from the toolbar.
        private var split: some View {
            ArrangementView {
                ScrollView {
                    VStack(spacing: 20) {
                        artwork
                            .containerRelativeFrame(.vertical) { height, _ in height * 0.45 }
                        titles
                        controls
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical)
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .background { backdrop }
                .modifier(SplitAxisReader(isSplit: $isSplit))
                .splitArrangementLayoutRatio(0.5)
            } secondary: {
                details
            }
            .arrangementViewStyle(.split.axes(.horizontal))
        }

        /// Laptop pose: the controls are primary, on the stable bottom half, and the cover and
        /// titles are secondary, on the top half. The overlay style keeps both clear of the hinge.
        /// VoiceOver reads the titles first, as in the column.
        private var tabletop: some View {
            ArrangementView {
                ViewThatFits(in: .vertical) {
                    controlsStack
                    ScrollView { controlsStack }
                }
                .accessibilitySortPriority(0)
                .overlayArrangementEdge(.bottom)
            } secondary: {
                ScrollView {
                    VStack(spacing: 12) {
                        artwork
                            .containerRelativeFrame(.vertical) { height, _ in height * 0.6 }
                        titles
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .background { backdrop }
                .accessibilitySortPriority(1)
            }
            .arrangementViewStyle(.overlay)
            .accessibilityElement(children: .contain)
        }

        private var controlsStack: some View {
            VStack(spacing: 20) { controls }
                .padding(.horizontal, 24)
                .padding(.vertical)
        }
    }

    /// Reports whether the enclosing split arrangement is side by side.
    @available(iOS 27.1, *)
    private struct SplitAxisReader: ViewModifier {
        @Binding var isSplit: Bool
        @Environment(\.splitArrangementAxis) private var axis

        func body(content: Content) -> some View {
            content.onChange(of: axis != nil, initial: true) { _, split in isSplit = split }
        }
    }

    /// The artwork as a backdrop: filling the safe area, unclipped by corners, under a material so
    /// the controls stay legible, and extended under the bars and the vertical toolbar.
    @available(iOS 27.1, *)
    struct PlayerBackdrop: View {
        let model: PlayerViewModel
        let shape: CoverShape

        var body: some View {
            Color.clear
                .overlay {
                    CoverView(
                        key: model.coverKey, title: model.title, author: model.author, shape: shape,
                        accessibility: .hidden
                    )
                    .aspectRatio(1 / shape.aspectRatio, contentMode: .fill)
                }
                .overlay { Rectangle().fill(.regularMaterial) }
                .clipped()
                .backgroundExtensionEffect()
                .accessibilityHidden(true)
        }
    }

    /// The split arrangement's secondary pane: chapters, Up Next and bookmarks, one at a time.
    /// Bookmarks only show where the toolbar would show them.
    struct PlayerDetailsPane: View {
        let model: PlayerViewModel
        @Binding var tab: PlayerDetailsTab
        /// The bookmark form's target, which a host outside the arrangement presents.
        @Binding var bookmarkEditor: BookmarkEditorTarget?
        @Environment(\.bookmarkStore) private var store

        var body: some View {
            let visible = PlayerDetailsTab.visible(
                showsBookmarks: BookmarksSlotPresentation(player: model, store: store).isVisible)
            let shown = tab.shown(in: visible)
            VStack(spacing: 0) {
                Picker(selection: Binding(get: { shown }, set: { tab = $0 })) {
                    ForEach(visible, id: \.self) { tab in
                        Text(verbatim: L10n.string(tab.titleKey)).tag(tab)
                    }
                } label: {
                    Text(verbatim: L10n.string("HeaderDetails"))
                }
                .pickerStyle(.segmented)
                .padding()
                switch shown {
                case .chapters:
                    ChaptersPane(model: model, onSelect: {})
                case .upNext:
                    // The queue isn't built yet (#60), like the shell's queue inspector.
                    ContentUnavailableView {
                        Label {
                            Text(verbatim: L10n.string("MessageNoItems"))
                        } icon: {
                            Image(systemName: "list.bullet")
                        }
                    }
                case .bookmarks:
                    BookmarksPane(model: model, editor: $bookmarkEditor, onSelect: {})
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// The column layout's toolbar while the toolbar is a vertical bar (the iPhone Duo's outer
    /// display): the full transport (``TransportToolbarItems``), preferring the vertical bar and
    /// kept visible, with the other actions in the overflow menu. Their sheets open on the
    /// trailing edge (``PlayerSheet``).
    @available(iOS 27.1, *)
    struct PlayerVerticalToolbar: ToolbarContent {
        let model: PlayerViewModel
        @Binding var sheet: PlayerSheet?
        @Environment(\.locale) private var locale
        @Environment(AppSettings.self) private var settings: AppSettings?

        var body: some ToolbarContent {
            TransportToolbarItems(
                showsPause: model.showsPause, isBuffering: model.isBuffering,
                jumpBackwardSeconds: model.jumpBackwardSeconds, jumpForwardSeconds: model.jumpForwardSeconds,
                hasPreviousChapter: model.hasPreviousChapter, hasNextChapter: model.hasNextChapter,
                showsSkipControls: model.displayOptions.showsSkipControls,
                haptic: settings?.hapticFeedback ?? .off, locale: locale
            ) { action in
                Task { await model.perform(action) }
            }
            ToolbarOverflowMenu {
                ChaptersSlot(model: model, sheet: $sheet)
                BookmarksSlot(model: model, sheet: $sheet)
                SleepTimerSlot(model: model, sheet: $sheet)
                QueueSlot(sheet: $sheet)
                PlayerOptionsMenu(model: model)
            }
        }
    }

    @available(iOS 27.1, *)
    #Preview("Split") {
        NowPlayingView(
            model: .preview(at: 9_500, playing: true),
            forcedLayout: .init(arrangement: .split, transportInToolbar: false))
    }

    @available(iOS 27.1, *)
    #Preview("Tabletop") {
        NowPlayingView(
            model: .preview(at: 9_500, playing: true),
            forcedLayout: .init(arrangement: .tabletop, transportInToolbar: false))
    }

    @available(iOS 27.1, *)
    #Preview("Tabletop, accessibility size") {
        NowPlayingView(
            model: .preview(at: 9_500, playing: true),
            forcedLayout: .init(arrangement: .tabletop, transportInToolbar: false)
        )
        .dynamicTypeSize(.accessibility3)
    }

    @available(iOS 27.1, *)
    #Preview("Column, vertical toolbar") {
        NowPlayingView(
            model: .preview(at: 9_500, playing: true),
            forcedLayout: .init(arrangement: .column, transportInToolbar: true))
    }

    #Preview("Details pane") {
        @Previewable @State var tab = PlayerDetailsTab.chapters
        @Previewable @State var editor: BookmarkEditorTarget?
        PlayerDetailsPane(model: .preview(at: 9_500), tab: $tab, bookmarkEditor: $editor)
    }
#endif
