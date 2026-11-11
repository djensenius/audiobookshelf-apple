import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The Home tab (legacy `pages/bookshelf/index.vue`): the personalized shelves of the router's
/// current library.
///
/// Signed out (no `libraryStore` in the environment) it shows the signed-out state. Signed in it
/// hosts one ``HomeModel`` per store and account connection (ADR 0004): the scene's subtree is
/// already keyed by the session identity, and keying ``HomeScreen`` by the connection too means
/// signing out and back in to the same account never shows the previous model's shelves.
struct HomeView: View {
    @Environment(\.libraryStore) private var store

    var body: some View {
        Group {
            if let store {
                HomeScreen(store: store)
                    .id(HomeModelIdentity(store: ObjectIdentifier(store), connection: store.connectionKey))
            } else {
                HomeContent(
                    state: .signedOut, sections: [], context: HomePresentation.actionContext(canPlay: false),
                    open: { _ in }, perform: { _, _ in }, retry: {})
            }
        }
        .navigationTitle(Text(verbatim: L10n.string("ButtonHome")))
    }
}

/// What ``HomeScreen`` is keyed by: a new store or connection gets a new ``HomeModel``.
private struct HomeModelIdentity: Hashable {
    let store: ObjectIdentifier
    let connection: LibraryConnectionKey?
}

/// Home while signed in: owns the ``HomeModel``, loads the router's library, and performs the
/// card actions through the environment.
private struct HomeScreen: View {
    let store: LibraryStore
    @State private var model: HomeModel
    /// The key of the message for the last failed action, shown as an alert.
    @State private var failureKey: String?
    @Environment(Router.self) private var router: Router?
    @Environment(\.itemActions) private var itemActions
    @Environment(\.playItem) private var playItem

    init(store: LibraryStore) {
        self.store = store
        _model = State(initialValue: HomeModel(store: store))
    }

    var body: some View {
        let libraryID = router?.libraryID
        // `sections` is rebuilt on every read: read it once.
        let sections = model.sections
        // Until the task below adopts a new library, the model still shows the old one.
        let isCurrent = model.libraryID == libraryID
        let state = HomeScreenState.resolve(
            hasStore: true, libraryID: libraryID, hasLoaded: isCurrent && model.hasLoaded,
            isLoading: model.isLoading, hasError: isCurrent && model.error != nil, isEmpty: sections.isEmpty)
        HomeContent(
            state: state, sections: sections, context: HomePresentation.actionContext(canPlay: playItem != nil),
            open: { navigate(to: $0) }, perform: { perform($0, on: $1) }, retry: { Task { await model.refresh() } }
        )
        .environment(\.itemProgressReader, progressReader)
        .refreshable { await model.refresh() }
        .task(id: libraryID) {
            model.libraryID = libraryID
            await model.load()
        }
        .alert(
            Text(verbatim: failureKey.map { L10n.string($0) } ?? ""),
            isPresented: Binding(get: { failureKey != nil }, set: { if !$0 { failureKey = nil } })
        ) {
            Button(L10n.string("ButtonOk")) { failureKey = nil }
        }
    }

    /// The store's progress, which the action menus and progress bars read.
    private var progressReader: ItemProgressReader {
        let progress = store.progress
        return ItemProgressReader { itemID, episodeID in
            progress.progress(libraryItemID: itemID, episodeID: episodeID).map(ItemProgress.init)
        }
    }

    /// Pushes `route` on the Home tab's stack, the stack this screen is the root of.
    private func navigate(to route: Route) {
        router?[path: .home].append(route)
    }

    private func perform(_ kind: ItemActionKind, on item: ItemSummary) {
        let actions = itemActions
        let play = playItem
        Task {
            if let key = await HomePresentation.perform(kind, on: item, actions: actions, play: play) {
                failureKey = key
            }
        }
    }
}

/// Home for one ``HomeScreenState``. Has no model, so previews show every state with fixtures.
struct HomeContent: View {
    let state: HomeScreenState
    let sections: [HomeSection]
    let context: ItemActionContext
    let open: (Route) -> Void
    let perform: (ItemActionKind, ItemSummary) -> Void
    let retry: () -> Void

    var body: some View {
        switch state {
        case .signedOut:
            HomeMessageView(
                title: L10n.string("MessageBookshelfEmpty"),
                message: L10n.string("MessageAudiobookshelfServerNotConnected"), systemImage: "icloud.slash")
        case .loading:
            LoadingView()
        case .failed:
            ErrorStateView(title: L10n.string("MessageHomeLoadFailed"), retry: retry)
        case .empty:
            HomeMessageView(
                title: L10n.string("MessageBookshelfEmpty"), systemImage: "books.vertical", refreshable: true)
        case .shelves(let refreshFailed):
            HomeShelvesView(
                sections: sections, refreshFailed: refreshFailed, context: context, open: open, perform: perform,
                retry: retry)
        }
    }
}

/// A full-screen message. In a scroll view when `refreshable`, so pull to refresh still works
/// when there's nothing to show.
private struct HomeMessageView: View {
    let title: String
    var message: String?
    let systemImage: String
    var refreshable = false

    var body: some View {
        if refreshable {
            ScrollView(.vertical) {
                unavailable.containerRelativeFrame([.horizontal, .vertical])
            }
        } else {
            unavailable
        }
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
        } description: {
            if let message {
                Text(verbatim: message)
            }
        }
    }
}

#Preview("Loaded") {
    NavigationStack {
        HomeContent(
            state: .shelves(refreshFailed: false), sections: HomePreviewData.sections,
            context: HomePresentation.actionContext(canPlay: true), open: { _ in }, perform: { _, _ in },
            retry: {}
        )
        .navigationTitle(Text(verbatim: L10n.string("ButtonHome")))
    }
    .environment(\.serverID, UUID())
    .environment(\.itemProgressReader, HomePreviewData.progressReader)
    .absBackground()
}

#Preview("Empty") {
    NavigationStack {
        HomeContent(
            state: .empty, sections: [], context: HomePresentation.actionContext(canPlay: true), open: { _ in },
            perform: { _, _ in }, retry: {}
        )
        .navigationTitle(Text(verbatim: L10n.string("ButtonHome")))
    }
    .absBackground()
}

#Preview("Error") {
    NavigationStack {
        HomeContent(
            state: .failed, sections: [], context: HomePresentation.actionContext(canPlay: true), open: { _ in },
            perform: { _, _ in }, retry: {}
        )
        .navigationTitle(Text(verbatim: L10n.string("ButtonHome")))
    }
    .absBackground()
}

#Preview("Signed out, dark") {
    NavigationStack { HomeView() }
        .absBackground()
        .preferredColorScheme(.dark)
}
