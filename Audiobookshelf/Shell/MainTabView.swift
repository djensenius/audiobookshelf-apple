import ABSAppModel
import ABSUI
import SwiftUI

/// The signed-in shell (ADR 0004): one `TabView`, a tab bar in compact width and a sidebar
/// elsewhere, with a `NavigationStack` per tab driven by the scene's ``Router``. Every stack has
/// the one `Route` destination, so a screen is added in ``RouteDestination``, not here. Each tab's
/// root is its feature's screen (``TabRoot``); the sidebar shows only the library's sections.
struct MainTabView: View {
    @Bindable var router: Router
    let player: any PlayerSlotState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        TabView(selection: $router.selectedTab) {
            tab(.home)
            tab(.library)
            // Sidebar only. The compact tab bar reaches these through the Library root's section
            // picker, which `Router.normalize(isCompact:)` keeps in step. Only the sections the
            // current library shows for this user are listed, as in the legacy `BookshelfNavBar.vue`.
            if !router.visibleSections.isEmpty {
                TabSection {
                    ForEach(router.visibleSections, id: \.self) { section in
                        tab(section)
                    }
                } header: {
                    Text(verbatim: L10n.string("HeaderBrowse"))
                }
                .defaultVisibility(.hidden, for: .tabBar)
            }
            tab(.downloads)
            tab(.account)
            tab(.search, role: .search)
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSidebarHeader { LibraryPickerHeader() }
        #if os(iOS)
            .defaultTabBarPlacement(.sidebar)
            .tabBarMinimizeBehavior(.onScrollDown)
        #endif
        .modifier(PlayerSlot(router: router, player: player))
        .onChange(of: horizontalSizeClass) { _, sizeClass in
            router.normalize(isCompact: sizeClass == .compact)
        }
    }

    private func tab(_ tab: AppTab, role: TabRole? = nil) -> some TabContent<AppTab> {
        Tab(value: tab, role: role) {
            NavigationStack(path: $router[path: tab]) {
                TabRoot(tab: tab, librarySection: router.librarySection)
                    .navigationDestination(for: Route.self) { route in
                        RouteDestination(route: route)
                    }
            }
        } label: {
            Label {
                Text(verbatim: L10n.string(tab.titleKey))
            } icon: {
                Image(systemName: tab.systemImage)
            }
        }
    }
}

/// The root screen of a tab: its feature's screen. In compact width the Library tab shows the
/// selected ``Router/librarySection`` instead of the default grid.
struct TabRoot: View {
    let tab: AppTab
    var librarySection: AppTab?

    var body: some View {
        switch tab {
        case .home: HomeView()
        case .library:
            if let librarySection, librarySection.isSection {
                TabRoot(tab: librarySection)
            } else {
                LibraryView()
            }
        case .search: SearchView()
        case .downloads: DownloadsView()
        case .account: AccountView()
        case .series: SeriesView()
        case .collections: CollectionsView()
        case .authors: AuthorsView()
        case .playlists: PlaylistsView()
        case .latest: LatestView()
        case .addPodcast: AddPodcastView()
        }
    }
}

extension AppTab {
    /// The key of the tab's title in the string catalog; the sidebar-only sections use the
    /// legacy `BookshelfNavBar.vue` names.
    var titleKey: String {
        switch self {
        case .home: "ButtonHome"
        case .library: "ButtonLibrary"
        case .search: "ButtonSearch"
        case .downloads: "HeaderDownloads"
        case .account: "HeaderAccount"
        case .series: "ButtonSeries"
        case .collections: "ButtonCollections"
        case .authors: "ButtonAuthors"
        case .playlists: "ButtonPlaylists"
        case .latest: "ButtonLatest"
        case .addPodcast: "ButtonAdd"
        }
    }

    /// The SF Symbol of the tab.
    var systemImage: String {
        switch self {
        case .home: "house"
        case .library: "books.vertical"
        case .search: "magnifyingglass"
        case .downloads: "arrow.down.circle"
        case .account: "person.crop.circle"
        case .series: "rectangle.stack"
        case .collections: "square.stack"
        case .authors: "person.2"
        case .playlists: "music.note.list"
        case .latest: "clock"
        case .addPodcast: "plus.circle"
        }
    }
}

#Preview {
    MainTabView(router: Router(), player: PlaceholderPlayerState(hasSession: true, title: "Preview"))
}
