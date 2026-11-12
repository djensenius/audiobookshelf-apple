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
                    state: .signedOut, sections: [], context: ItemCardActions.actionContext(canPlay: false),
                    open: { _ in }, perform: { _, _ in }, retry: {})
            }
        }
        // The signed-in shell's first screen, for UI tests.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.screen")
        .navigationTitle(Text(verbatim: L10n.string("ButtonHome")))
    }
}

/// What ``HomeScreen`` is keyed by: a new store or connection gets a new ``HomeModel``.
private struct HomeModelIdentity: Hashable {
    let store: ObjectIdentifier
    let connection: LibraryConnectionKey?
}

/// Home while signed in: owns the ``HomeModel``, loads the router's library, reloads shelves
/// that have gone stale, and performs the card actions through the environment.
private struct HomeScreen: View {
    let store: LibraryStore
    @State private var model: HomeModel
    @State private var schedule = HomeRefreshSchedule()
    /// Built once, so the cards don't all re-render on every body.
    @State private var progressReader: ItemProgressReader
    /// The key of the message for the last failed action, kept while the alert is dismissed.
    @State private var failureKey: String?
    @State private var showsFailure = false
    @Environment(Router.self) private var router: Router?
    @Environment(\.itemActions) private var itemActions
    @Environment(\.playItem) private var playItem
    @Environment(\.scenePhase) private var scenePhase

    init(store: LibraryStore) {
        self.store = store
        _model = State(initialValue: HomeModel(store: store))
        let progress = store.progress
        _progressReader = State(
            initialValue: ItemProgressReader { itemID, episodeID in
                progress.progress(libraryItemID: itemID, episodeID: episodeID).map(ItemProgress.init)
            })
    }

    var body: some View {
        let libraryID = router?.libraryID
        // `sections` is rebuilt on every read: read it once.
        let sections = model.sections
        let state = HomeScreenState.resolve(store: store, model: model, libraryID: libraryID, sections: sections)
        HomeContent(
            state: state, sections: sections, context: ItemCardActions.actionContext(canPlay: playItem != nil),
            open: { navigate(to: $0) }, perform: { perform($0, on: $1) }, retry: { Task { await refresh() } }
        )
        // TODO(#181): drop this once the shell sets `itemProgressReader` from the same store.
        .environment(\.itemProgressReader, progressReader)
        .refreshable { await refresh() }
        .task(id: libraryID) {
            model.libraryID = libraryID
            await update()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await update() } }
        }
        .refreshCommand(.root(.home), isDisabled: store.isLoading || model.isLoading) { Task { await refresh() } }
        .alert(
            Text(verbatim: failureKey.map { L10n.string($0) } ?? ""), isPresented: $showsFailure,
            presenting: failureKey
        ) { _ in
            Button(L10n.string("ButtonOk")) {}
        }
    }

    /// Loads the shelves if needed, or reloads them when `force` or stale.
    private func update(force: Bool = false) async {
        guard let libraryID = model.libraryID,
            let request = schedule.request(
                libraryID: libraryID, hasLoaded: model.hasLoaded, now: .now, force: force)
        else { return }
        switch request {
        case .load: await model.load()
        case .refresh: await model.refresh()
        }
        schedule.recordCompletion(
            of: libraryID,
            model: .init(
                libraryID: model.libraryID, hasLoaded: model.hasLoaded, isLoading: model.isLoading,
                hasError: model.error != nil),
            isCancelled: Task.isCancelled, at: .now)
    }

    /// Pull to refresh, the Refresh command and Retry: the libraries while none is selected,
    /// otherwise the shelves.
    private func refresh() async {
        if model.libraryID == nil {
            await store.refresh()
        } else {
            await update(force: true)
        }
    }

    /// Pushes `route` on the Home tab's stack, the stack this screen is the root of, unless it is
    /// already on top (a double tap).
    private func navigate(to route: Route) {
        guard let router, router[path: .home].last != route else { return }
        router[path: .home].append(route)
    }

    private func perform(_ kind: ItemActionKind, on item: ItemSummary) {
        let actions = itemActions
        let play = playItem
        Task {
            if let key = await ItemCardActions.perform(kind, on: item, actions: actions, play: play) {
                failureKey = key
                showsFailure = true
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
        case .failed, .librariesFailed:
            // In a scroll view, so pull to refresh works as well as Retry.
            HomeScrollableState {
                ErrorStateView(title: L10n.string("MessageHomeLoadFailed"), retry: retry)
            }
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

/// A full-screen state centred in a vertical scroll view, so `.refreshable` reaches it.
private struct HomeScrollableState<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            content.containerRelativeFrame([.horizontal, .vertical])
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
            HomeScrollableState { unavailable }
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

#if DEBUG
    #Preview("Loaded") {
        NavigationStack {
            HomeContent(
                state: .shelves(refreshFailed: false), sections: HomePreviewData.sections,
                context: ItemCardActions.actionContext(canPlay: true), open: { _ in }, perform: { _, _ in },
                retry: {}
            )
            .navigationTitle(Text(verbatim: L10n.string("ButtonHome")))
        }
        .environment(\.serverID, UUID())
        .environment(\.itemProgressReader, HomePreviewData.progressReader)
        .absBackground()
    }
#endif

#Preview("Empty") {
    NavigationStack {
        HomeContent(
            state: .empty, sections: [], context: ItemCardActions.actionContext(canPlay: true), open: { _ in },
            perform: { _, _ in }, retry: {}
        )
        .navigationTitle(Text(verbatim: L10n.string("ButtonHome")))
    }
    .absBackground()
}

#Preview("Error") {
    NavigationStack {
        HomeContent(
            state: .failed, sections: [], context: ItemCardActions.actionContext(canPlay: true), open: { _ in },
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
