import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// Home's loaded shelves (legacy `pages/bookshelf/index.vue`): one lazy horizontal ``ShelfRow``
/// per section, under a notice when the last reload failed. Has no model, so previews pass
/// fixture sections.
struct HomeShelvesView: View {
    let sections: [HomeSection]
    var refreshFailed = false
    let context: ItemActionContext
    /// Opens an entry's screen.
    let open: (Route) -> Void
    /// Performs an action other than ``ItemActionKind/openDetails`` on an item.
    let perform: (ItemActionKind, ItemSummary) -> Void
    let retry: () -> Void

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: ABSSpacing.xLarge) {
                if refreshFailed {
                    HomeRefreshFailedRow(retry: retry)
                        .padding(.horizontal, ABSSpacing.large)
                }
                ForEach(sections) { section in
                    HomeSectionRow(section: section, context: context, open: open, perform: perform)
                }
            }
            .padding(.vertical, ABSSpacing.large)
        }
    }
}

/// One section as a shelf of the cards its kind calls for. Opens a card in a new window itself
/// (``OpenInNewWindow``), where the device has windows.
struct HomeSectionRow: View {
    let section: HomeSection
    let context: ItemActionContext
    let open: (Route) -> Void
    let perform: (ItemActionKind, ItemSummary) -> Void
    @Environment(\.serverID) private var serverID
    @Environment(\.locale) private var locale
    @Environment(Router.self) private var router: Router?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    private var libraries = LibraryCoverSettings()

    var body: some View {
        ShelfRow(
            title: HomePresentation.title(of: section, locale: locale), elements: section.entries,
            cardWidth: HomePresentation.cardWidth(for: section.kind)
        ) { entry in
            card(for: entry)
        }
    }

    @ViewBuilder private func card(for entry: HomeEntry) -> some View {
        switch entry {
        case .item(let item):
            ItemCard(
                item: item, serverID: serverID, librarySettings: libraries.current, context: itemContext
            ) { kind in
                switch kind {
                case .openDetails: open(ItemCardActions.route(for: item))
                case .openInNewWindow:
                    OpenInNewWindow.open(ItemCardActions.route(for: item), from: router, with: openWindow)
                default: perform(kind, item)
                }
            }
        case .series(let series):
            SeriesCard(series: series, serverID: serverID) { open(HomePresentation.route(for: entry)) }
                .openInNewWindowMenu(HomePresentation.route(for: entry))
        case .author(let author):
            AuthorCard(author: author, serverID: serverID) { open(HomePresentation.route(for: entry)) }
                .openInNewWindowMenu(HomePresentation.route(for: entry))
        }
    }

    private var itemContext: ItemActionContext {
        var context = context
        context.canOpenInNewWindow = supportsMultipleWindows
        return context
    }
}

/// Shown above the retained shelves when a reload fails.
private struct HomeRefreshFailedRow: View {
    let retry: () -> Void

    var body: some View {
        HStack(spacing: ABSSpacing.medium) {
            Label {
                Text(verbatim: L10n.string("MessageHomeRefreshFailed"))
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(ABSColor.mutedForeground)
                    .accessibilityHidden(true)
            }
            .font(.subheadline)
            Spacer(minLength: ABSSpacing.small)
            Button(action: retry) {
                Text(verbatim: L10n.string("ButtonRetry"))
            }
            .buttonStyle(.borderless)
        }
        .accessibilityElement(children: .contain)
    }
}

#if DEBUG
    /// Fixture sections and progress for previews.
    enum HomePreviewData {
        static let sections = HomeSection.sections(from: SampleLibrary.shelves) { _, _ in nil }

        static let progressReader = ItemProgressReader { itemID, episodeID in
            SampleLibrary.progress[MediaProgress.key(libraryItemID: itemID, episodeID: episodeID)]
        }
    }

    #Preview("Shelves") {
        NavigationStack {
            HomeShelvesView(
                sections: HomePreviewData.sections, context: ItemCardActions.actionContext(canPlay: true),
                open: { _ in }, perform: { _, _ in }, retry: {}
            )
            .navigationTitle(Text(verbatim: L10n.string("ButtonHome")))
        }
        .environment(\.serverID, UUID())
        .environment(\.itemProgressReader, HomePreviewData.progressReader)
        .absBackground()
    }

    #Preview("Shelves, refresh failed, largest text") {
        NavigationStack {
            HomeShelvesView(
                sections: HomePreviewData.sections, refreshFailed: true,
                context: ItemCardActions.actionContext(canPlay: false), open: { _ in }, perform: { _, _ in },
                retry: {}
            )
        }
        .environment(\.itemProgressReader, HomePreviewData.progressReader)
        .environment(\.dynamicTypeSize, .accessibility3)
        .absBackground()
    }
#endif
