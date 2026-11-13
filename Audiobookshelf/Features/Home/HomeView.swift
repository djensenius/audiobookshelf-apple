import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The Home tab (legacy `pages/bookshelf/index.vue`): the personalized shelves of the router's
/// current library, then the downloaded shelf of its kind; without the server, only the
/// downloaded shelves, or why there's nothing to show.
///
/// Signed out (no `libraryStore` in the environment) it shows the signed-out state. Signed in it
/// hosts one ``HomeModel`` per store and account connection (ADR 0004): the scene's subtree is
/// already keyed by the session identity, and keying ``HomeScreen`` by the connection too means
/// signing out and back in to the same account never shows the previous model's shelves.
struct HomeView: View {
    @Environment(\.libraryStore) private var store
    @Environment(\.downloads) private var downloads

    var body: some View {
        Group {
            if let store {
                HomeScreen(store: store, downloadUpdates: downloads?.localItemUpdates)
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

/// What Home's load runs again on.
private struct HomeLoadTrigger: Hashable {
    let libraryID: String?
    let connection: LibraryConnectionKey?
    let onlineRevision: Int
    /// The server answers, so a load that failed while it didn't runs again.
    let isConnected: Bool
}

/// Home while signed in: owns the ``HomeModel`` and the ``DownloadedShelfModel``, loads the
/// router's library, reloads shelves that have gone stale, and performs the card actions through
/// the environment.
private struct HomeScreen: View {
    let store: LibraryStore
    @State private var model: HomeModel
    /// `nil` without a download stack.
    @State private var downloaded: DownloadedShelfModel?
    @State private var schedule = HomeRefreshSchedule()
    /// The key of the message for the last failed action, kept while the alert is dismissed.
    @State private var failureKey: String?
    @State private var showsFailure = false
    @Environment(Router.self) private var router: Router?
    @Environment(\.itemActions) private var itemActions
    @Environment(\.playItem) private var playItem
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.connectionBanner) private var connectionBanner

    /// - Parameter downloadUpdates: The account's downloaded items as they change, or `nil`
    ///   without a download stack.
    init(store: LibraryStore, downloadUpdates: DownloadedShelfModel.Updates?) {
        self.store = store
        _model = State(initialValue: HomeModel(store: store))
        _downloaded = State(initialValue: downloadUpdates.map { DownloadedShelfModel(updates: $0) })
    }

    var body: some View {
        let libraryID = router?.libraryID
        // `sections` is rebuilt on every read: read it once.
        let serverSections = model.sections
        let connection = connectionStatus
        let downloads = HomePresentation.downloadedSections(
            of: downloaded, libraryKind: router?.libraryKind, isConnected: connection == nil)
        let state = HomeScreenState.resolve(
            store: store, model: model, libraryID: libraryID, sections: serverSections, connection: connection,
            downloads: downloads, downloadsLoaded: downloaded?.isLoaded ?? true,
            downloadsFailed: downloaded?.loadError != nil)
        HomeContent(
            state: state,
            sections: HomePresentation.sections(
                server: serverSections, downloaded: downloads, isConnected: connection == nil),
            context: ItemCardActions.actionContext(canPlay: playItem != nil), open: { navigate(to: $0) },
            perform: { perform($0, on: $1) }, retry: { Task { await refresh() } },
            retryConnection: { connectionBanner?.model.retry() }
        )
        .refreshable { await refresh() }
        // With the client, the online revision and the connection too: a reconnect, whether it
        // attaches a client after an offline start without one or keeps the offline session's,
        // or the server answering again, loads again even when the library is unchanged, and
        // retries a failed load or refresh even while the shelves are fresh, or, with no library
        // yet, a failed libraries list, waiting for either in flight. Losing the connection runs
        // it too, and makes no request.
        .task(
            id: HomeLoadTrigger(
                libraryID: libraryID, connection: store.connectedKey, onlineRevision: store.onlineRevision,
                isConnected: connection == nil)
        ) {
            model.libraryID = libraryID
            await update(.loadTrigger)
        }
        // The downloads follow the store live, online and offline.
        .task(id: store.connectionKey?.connectionID) {
            await downloaded?.observe(connectionID: store.connectionKey?.connectionID)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await update(.sceneActivation) } }
        }
        .refreshCommand(.root(.home), isDisabled: store.isLoading || model.isLoading) { Task { await refresh() } }
        .alert(
            Text(verbatim: failureKey.map { L10n.string($0) } ?? ""), isPresented: $showsFailure,
            presenting: failureKey
        ) { _ in
            Button(L10n.string("ButtonOk")) {}
        }
    }

    /// Loads the shelves, or reloads them, as ``HomeRefreshSchedule`` decides for `trigger`:
    /// nothing without the server. Without a library, the libraries list instead, which selects
    /// one once loaded.
    private func update(_ trigger: HomeRefreshSchedule.Trigger) async {
        guard let libraryID = model.libraryID else {
            await HomeRefreshSchedule.updateLibraries(
                of: store, for: trigger, isConnected: { connectionStatus == nil })
            return
        }
        if let request = schedule.request(
            for: trigger, libraryID: libraryID, hasLoaded: model.hasLoaded, hasError: model.error != nil,
            isConnected: connectionStatus == nil, now: .now)
        {
            switch request {
            case .load: await model.load()
            case .refresh: await model.refresh()
            }
        } else {
            // Fresh shelves without an error: a refresh in flight that may have started before
            // the server answered again is waited for, and retried once if it fails.
            guard
                await HomeRefreshSchedule.updateShelvesAfterInFlight(
                    of: model, for: trigger, isConnected: { connectionStatus == nil })
            else { return }
        }
        schedule.recordCompletion(
            of: libraryID,
            model: .init(
                libraryID: model.libraryID, hasLoaded: model.hasLoaded, isLoading: model.isLoading,
                hasError: model.error != nil),
            isCancelled: Task.isCancelled, at: .now)
    }

    /// Pull to refresh, the Refresh command and Retry: the libraries while none is selected,
    /// otherwise the shelves. Without the server, it checks the server again instead. Downloads
    /// that couldn't be read are read again either way.
    private func refresh() async {
        downloaded?.retry()
        if let connectionBanner, connectionStatus != nil {
            connectionBanner.model.retry()
        } else {
            await update(.userRefresh)
        }
    }

    /// Why the server can't be used, as the shell's connection banner shows it; `nil` online, or
    /// without a banner (previews).
    private var connectionStatus: ConnectionBannerStatus? {
        connectionBanner.flatMap { ConnectionBannerPresentation.status(for: $0.model.state) }
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
    /// Checks the server again (the connection banner's Retry).
    var retryConnection: () -> Void = {}

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
        case .disconnected(let status):
            // Legacy's empty bookshelf with the connection's message.
            HomeScrollableState {
                ErrorStateView(
                    title: L10n.string("MessageBookshelfEmpty"), message: status.message,
                    systemImage: status.systemImage,
                    retry: HomePresentation.connectionRetry(for: status, retry: retryConnection))
            }
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

#Preview("Server unreachable, nothing downloaded") {
    NavigationStack {
        HomeContent(
            state: .disconnected(.serverUnreachable(retryAt: .now.addingTimeInterval(30))), sections: [],
            context: ItemCardActions.actionContext(canPlay: true), open: { _ in }, perform: { _, _ in }, retry: {}
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
