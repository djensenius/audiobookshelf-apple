import ABSAppModel
import ABSCore
import ABSUI
import Foundation

/// What a series or author screen (the lists and the detail screens) shows, resolved from its
/// model by ``resolve(_:)``, or by ``placeholder(store:libraryID:)`` until the model exists.
enum BrowseScreenState: Hashable {
    /// No account is connected.
    case signedOut
    /// The first load hasn't finished.
    case loading
    /// The first load failed; the screen offers Retry.
    case failed
    /// The server answered 404.
    case notFound
    /// Loaded, with nothing to show.
    case empty
    /// Loaded; `failed` when a later load (a reload or the next page) failed.
    case loaded(failed: Bool)

    /// A model's state, as ``resolve(_:)`` reads it.
    struct Inputs: Hashable {
        /// A load has succeeded; for a paged list, a page arrived or the list is known empty.
        var hasLoaded = false
        /// There is something to show; detail screens always have their header.
        var hasContent = false
        var isLoading = false
        var hasError = false
        var isNotFound = false
    }

    static func resolve(_ inputs: Inputs) -> BrowseScreenState {
        if inputs.isNotFound { return .notFound }
        guard inputs.hasLoaded else { return inputs.hasError && !inputs.isLoading ? .failed : .loading }
        guard inputs.hasContent else { return inputs.hasError ? .failed : .empty }
        return .loaded(failed: inputs.hasError)
    }

    /// A paged list's state: loaded once a page arrived or the end was reached.
    @MainActor
    static func resolve<Query, Item>(list: ItemListModel<Query, Item>) -> BrowseScreenState {
        resolve(
            Inputs(
                hasLoaded: !list.items.isEmpty || list.reachedEnd, hasContent: !list.items.isEmpty,
                isLoading: list.isLoading, hasError: list.error != nil))
    }

    /// The state while the screen has no model: signed out, waiting for the libraries (or Retry
    /// when they failed), or empty when they loaded and none is selected.
    @MainActor
    static func placeholder(store: LibraryStore?, libraryID: String?) -> BrowseScreenState {
        guard let store, store.client != nil, store.connectionKey != nil else { return .signedOut }
        guard libraryID == nil else { return .loading }
        if store.hasLoaded { return .empty }
        return store.error != nil && !store.isLoading ? .failed : .loading
    }
}

/// What a screen's model is built for: a new store, account, library or entity gets a new model.
struct BrowseModelKey: Hashable {
    let store: ObjectIdentifier
    let connection: LibraryConnectionKey
    let libraryID: String
    /// The series or author of a detail screen.
    let entityID: String?

    /// `nil` while signed out or before the scene has a library.
    @MainActor
    init?(store: LibraryStore?, libraryID: String?, entityID: String? = nil) {
        guard let store, store.client != nil, let connection = store.connectionKey, let libraryID else { return nil }
        self.store = ObjectIdentifier(store)
        self.connection = connection
        self.libraryID = libraryID
        self.entityID = entityID
    }
}

/// A screen's model with the key it was built for, kept in `@State`.
struct BrowseModelHost<Model: AnyObject> {
    let key: BrowseModelKey
    let model: Model
    /// The store's progress for item cards, built once so the cards don't all re-render on
    /// every body.
    let progressReader: ItemProgressReader

    /// Builds the model from the store's services; `nil` while the store serves no account or
    /// serves another account than `key`'s.
    @MainActor
    init?(key: BrowseModelKey, store: LibraryStore, make: (LibraryStoreServices) -> Model) {
        guard let services = store.makeServices(), services.connectionKey == key.connection else { return nil }
        self.key = key
        model = make(services)
        progressReader = BrowsePresentation.progressReader(store.progress)
    }

    /// The host a screen's task keeps for `key`: `host` itself when it was built for `key`, so
    /// the model and what it loaded survive, else a new one; `nil` without a key or a store.
    /// `make` gets the key, the store's services and its progress.
    @MainActor
    static func updated(
        _ host: Self?, for key: BrowseModelKey?, store: LibraryStore?,
        make: (BrowseModelKey, LibraryStoreServices, ProgressCache) -> Model
    ) -> Self? {
        guard let key, let store else { return nil }
        if let host, host.key == key { return host }
        return Self(key: key, store: store) { make(key, $0, store.progress) }
    }

    /// The model, unless it was built for another key (the view's task hasn't replaced it yet).
    func model(for key: BrowseModelKey?) -> Model? {
        key == self.key ? model : nil
    }
}

/// Navigation and paging shared by the series and author screens.
enum BrowsePresentation {
    /// Pushes `route` on the selected tab's path (the stack showing the screen) unless it is
    /// already on top, so a double tap opens one screen.
    @MainActor
    static func open(_ route: Route, in router: Router?) {
        guard let router else { return }
        let tab = router.selectedTab
        guard router[path: tab].last != route else { return }
        router[path: tab].append(route)
    }

    /// Retries a paged list: the next page, or a refresh when the list had reached its end (a
    /// failed refresh rolls back to the end, where the next page loads nothing).
    @MainActor
    @discardableResult
    static func retry<Query, Item>(_ list: ItemListModel<Query, Item>) -> Task<Void, Never>? {
        list.reachedEnd ? list.refresh() : list.loadNextPage()
    }

    /// Refreshes a paged list for the user (pull to refresh, Refresh) and returns whether it
    /// failed, which keeps the old items on screen.
    @MainActor
    static func refresh<Query, Item>(_ list: ItemListModel<Query, Item>) async -> Bool {
        await list.refresh()?.value
        return list.error != nil
    }

    /// Where a loaded paged list shows its failure.
    enum ListFailurePlacement: Hashable {
        /// A user refresh failed: above the old items, with Retry refreshing again.
        case top
        /// The next page failed: after the items, with Retry loading it again.
        case footer
    }

    /// Where a loaded paged list shows that its last load `failed`; `nil` when it didn't.
    static func failurePlacement(failed: Bool, refreshFailed: Bool) -> ListFailurePlacement? {
        guard failed else { return nil }
        return refreshFailed ? .top : .footer
    }

    /// The progress item cards show, read from the store's cache.
    @MainActor
    static func progressReader(_ cache: ProgressCache) -> ItemProgressReader {
        ItemProgressReader { itemID, episodeID in
            cache.progress(libraryItemID: itemID, episodeID: episodeID).map(ItemProgress.init)
        }
    }
}
