#if os(iOS)
    import ABSAppModel
    import ABSUI
    import SwiftUI

    /// The full player's arrangements on large and folding displays (#84), picked by
    /// ``PlayerLayout``: ``PlayerLayout/Arrangement/split`` and ``PlayerLayout/Arrangement/tabletop``.
    /// The column layout stays in ``NowPlayingView``.
    @available(iOS 27.1, *)
    struct PlayerArrangement<Artwork: View, Titles: View, Controls: View, Details: View>: View {
        let arrangement: PlayerLayout.Arrangement
        @ViewBuilder let artwork: Artwork
        @ViewBuilder let titles: Titles
        @ViewBuilder let controls: Controls
        @ViewBuilder let details: Details

        var body: some View {
            if arrangement == .tabletop {
                tabletop
            } else {
                split
            }
        }

        /// The cover, titles and controls as primary, the details as secondary, half and half.
        /// Side by side on a wide display (the inner display, flat or in book pose), stacked on a
        /// tall one.
        private var split: some View {
            ArrangementView {
                ScrollView {
                    VStack(spacing: 20) {
                        artwork
                            .containerRelativeFrame(.vertical) { height, _ in height * 0.45 }
                            .backgroundExtensionEffect()
                        titles
                        controls
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical)
                }
                .scrollBounceBehavior(.basedOnSize)
                .splitArrangementLayoutRatio(0.5)
            } secondary: {
                details
            }
            .arrangementViewStyle(.split)
        }

        /// Laptop pose: the controls are primary, on the stable bottom half, and the cover and
        /// titles are secondary, on the top half. The overlay style keeps both clear of the hinge.
        private var tabletop: some View {
            ArrangementView {
                ViewThatFits(in: .vertical) {
                    controlsStack
                    ScrollView { controlsStack }
                }
                .overlayArrangementEdge(.bottom)
            } secondary: {
                VStack(spacing: 12) {
                    artwork
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .backgroundExtensionEffect()
                    titles
                }
                .padding()
            }
            .arrangementViewStyle(.overlay)
        }

        private var controlsStack: some View {
            VStack(spacing: 20) { controls }
                .padding(.horizontal, 24)
                .padding(.vertical)
        }
    }

    /// The split arrangement's secondary pane: chapters, Up Next and bookmarks, one at a time.
    struct PlayerDetailsPane: View {
        enum Tab: CaseIterable {
            case chapters, upNext, bookmarks

            var titleKey: String {
                switch self {
                case .chapters: "HeaderChapters"
                case .upNext: "HeaderUpNext"
                case .bookmarks: "HeaderPlayerBookmarks"
                }
            }
        }

        let model: PlayerViewModel
        @State private var tab = Tab.chapters

        var body: some View {
            VStack(spacing: 0) {
                Picker(selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(verbatim: L10n.string(tab.titleKey)).tag(tab)
                    }
                } label: {
                    Text(verbatim: L10n.string("HeaderDetails"))
                }
                .pickerStyle(.segmented)
                .padding()
                switch tab {
                case .chapters:
                    ChaptersPane(model: model, onSelect: {})
                case .upNext:
                    // The queue isn't built yet (#60), like the shell's queue inspector.
                    placeholder(titleKey: "MessageNoItems", systemImage: "list.bullet")
                case .bookmarks:
                    // The bookmarks sheet is still a placeholder; its list replaces this (#410).
                    placeholder(titleKey: "LabelYourBookmarks", systemImage: "bookmark")
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }

        private func placeholder(titleKey: String, systemImage: String) -> some View {
            ContentUnavailableView {
                Label {
                    Text(verbatim: L10n.string(titleKey))
                } icon: {
                    Image(systemName: systemImage)
                }
            }
        }
    }

    /// The column layout's toolbar while the toolbar is a vertical bar (the iPhone Duo's outer
    /// display): the transport, preferring the vertical bar and kept visible, with the other
    /// actions in the overflow menu. Their sheets open on the trailing edge (``PlayerSheet``).
    @available(iOS 27.1, *)
    struct PlayerVerticalToolbar: ToolbarContent {
        let model: PlayerViewModel
        @Binding var sheet: PlayerSheet?
        @Environment(\.locale) private var locale

        var body: some ToolbarContent {
            ToolbarItemGroup(placement: .bottomBar) {
                jump(forward: false)
                Button {
                    Task { await model.perform(.playPause) }
                } label: {
                    Label {
                        Text(verbatim: TransportControls.playPauseLabel(showsPause: model.showsPause))
                    } icon: {
                        Image(systemName: model.showsPause ? "pause.fill" : "play.fill")
                    }
                }
                jump(forward: true)
            }
            .axisBehavior(.verticalPreferred)
            .visibilityPriority(.high)
            ToolbarOverflowMenu {
                ChaptersSlot(model: model, sheet: $sheet)
                BookmarksSlot(model: model, sheet: $sheet)
                SleepTimerSlot(model: model, sheet: $sheet)
                Button {
                } label: {
                    Label {
                        Text(verbatim: L10n.string("LabelMore"))
                    } icon: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .disabled(true)
            }
        }

        private func jump(forward: Bool) -> some View {
            let seconds = forward ? model.jumpForwardSeconds : model.jumpBackwardSeconds
            return Button {
                Task { await model.perform(forward ? .jumpForward : .jumpBackward) }
            } label: {
                Label {
                    Text(verbatim: TransportControls.jumpLabel(forward: forward, seconds: seconds, locale: locale))
                } icon: {
                    Image(systemName: TransportControls.jumpSymbol(forward: forward, seconds: seconds))
                }
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
    #Preview("Column, vertical toolbar") {
        NowPlayingView(
            model: .preview(at: 9_500, playing: true),
            forcedLayout: .init(arrangement: .column, transportInToolbar: true))
    }

    #Preview("Details pane") {
        PlayerDetailsPane(model: .preview(at: 9_500))
    }
#endif
