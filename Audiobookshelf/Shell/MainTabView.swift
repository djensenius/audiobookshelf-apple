import ABSAppModel
import ABSUI
import SwiftUI

/// The signed-in shell (ADR 0004): one `TabView`, a tab bar in compact width and a sidebar
/// elsewhere, with a `NavigationStack` per tab driven by the scene's ``Router``. Every stack has
/// the one `Route` destination, so a screen is added in ``RouteDestination``, not here. Each tab's
/// root is its feature's screen (``TabRoot``); the sidebar shows only the library's sections.
/// Every screen can read the router as `@Environment(Router.self)`, for its `libraryID` and
/// `libraryKind`.
struct MainTabView<Root: View>: View {
    @Bindable var router: Router
    let player: any PlayerSlotState
    /// The root screen of a tab, given the tab and the router's ``Router/librarySection``.
    /// ``TabRoot`` in the app; tests pass their own.
    let root: (AppTab, AppTab?) -> Root
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Tests only; the app uses `init(router:player:)`, whose roots are ``TabRoot``.
    init(
        router: Router, player: any PlayerSlotState, @ViewBuilder root: @escaping (AppTab, AppTab?) -> Root
    ) {
        self.router = router
        self.player = player
        self.root = root
    }

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
        .modifier(SceneLibrarySync(router: router))
        .onChange(of: horizontalSizeClass) { _, sizeClass in
            router.normalize(isCompact: sizeClass == .compact)
        }
        // Keep this the outermost modifier, so every tab stack, pushed `RouteDestination`, the
        // sidebar header and `PlayerSlot`'s presentations inherit the scene's router.
        .environment(router)
    }

    private func tab(_ tab: AppTab, role: TabRole? = nil) -> some TabContent<AppTab> {
        Tab(value: tab, role: role) {
            NavigationStack(path: $router[path: tab]) {
                root(tab, router.librarySection)
                    .navigationDestination(for: Route.self) { route in
                        RouteDestination(route: route)
                    }
                    .toolbar {
                        // The sidebar header picks the library in regular width.
                        if horizontalSizeClass == .compact, tab.isLibraryScoped, tab != .search {
                            LibraryPickerToolbar()
                        }
                    }
            }
            // Screens and their pushed routes know which tab's stack they're on, so a hidden tab's copy of the same
            // screen never takes ⌘R or ⌥⌘F (`RefreshCommandPlacement.isFrontmost`).
            .environment(\.navigationTab, tab)
        } label: {
            Label {
                Text(verbatim: L10n.string(tab.titleKey))
            } icon: {
                Image(systemName: tab.systemImage)
            }
        }
    }
}

extension MainTabView where Root == TabRoot {
    init(router: Router, player: any PlayerSlotState) {
        self.init(router: router, player: player) { tab, librarySection in
            TabRoot(tab: tab, librarySection: librarySection)
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

/// Opens Logs and, on iOS, Settings (a Mac has the Settings window), for the connect screen
/// and its signed-out stand-in, which have no Account tab. Needs the stack's `Route` destination.
struct DiagnosticsToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .secondaryAction) {
            NavigationLink(value: Route.logs) {
                Label {
                    Text(verbatim: L10n.string("ButtonLogs"))
                } icon: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
            }
        }
        #if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: Route.settings) {
                    Label {
                        Text(verbatim: L10n.string("HeaderSettings"))
                    } icon: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        #endif
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
