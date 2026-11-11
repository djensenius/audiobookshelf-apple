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

    /// Builds the model from the store's services; `nil` while the store serves no account.
    @MainActor
    init?(key: BrowseModelKey, store: LibraryStore, make: (LibraryStoreServices) -> Model) {
        guard let services = store.makeServices() else { return nil }
        self.key = key
        model = make(services)
        progressReader = BrowsePresentation.progressReader(store.progress)
    }

    /// The model, unless it was built for another key (the view's task hasn't replaced it yet).
    func model(for key: BrowseModelKey?) -> Model? {
        key == self.key ? model : nil
    }
}

/// Navigation, paging and card actions shared by the series and author screens.
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

    /// The screen an item card opens: its episode, its collapsed series, or the item.
    static func route(for item: ItemSummary) -> Route {
        switch item.kind {
        case .episode:
            if let episodeID = item.episodeID { return .episode(itemID: item.itemID, episodeID: episodeID) }
        case .series:
            if let seriesID = item.seriesID { return .series(id: seriesID) }
        case .book, .podcast:
            break
        }
        return .item(id: item.itemID)
    }

    /// Retries a paged list: the next page, or a refresh when the list had reached its end (a
    /// failed refresh rolls back to the end, where the next page loads nothing).
    @MainActor
    @discardableResult
    static func retry<Query, Item>(_ list: ItemListModel<Query, Item>) -> Task<Void, Never>? {
        list.reachedEnd ? list.refresh() : list.loadNextPage()
    }

    /// The progress item cards show, read from the store's cache.
    @MainActor
    static func progressReader(_ cache: ProgressCache) -> ItemProgressReader {
        ItemProgressReader { itemID, episodeID in
            cache.progress(libraryItemID: itemID, episodeID: episodeID).map(ItemProgress.init)
        }
    }

    /// Performs a context-menu action on `item`: Play through `play`, the progress actions
    /// through `actions`. Opening is navigation and isn't handled here; neither are sharing and
    /// playlists, which aren't wired up yet.
    ///
    /// - Returns: The key of the message to show when the action failed; `nil` when it succeeded,
    ///   was cancelled or did nothing.
    @MainActor
    static func perform(
        _ kind: ItemActionKind, on item: ItemSummary, actions: any ItemActionPerforming, play: PlayItemAction?
    ) async -> String? {
        let target = ItemActionTarget(libraryItemID: item.itemID, episodeID: item.episodeID, duration: item.duration)
        do {
            switch kind {
            case .play:
                guard let play else { return nil }
                try await play(itemID: item.itemID, episodeID: item.episodeID)
            case .markFinished: try await actions.markFinished(target)
            case .markNotFinished: try await actions.markNotFinished(target)
            case .hideFromContinueListening: try await actions.hideFromContinueListening(target)
            case .addToPlaylist, .share, .openDetails: return nil
            }
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return failureMessageKey(for: kind)
        }
    }

    /// The key of the message shown when an action on an item fails.
    static func failureMessageKey(for kind: ItemActionKind) -> String? {
        switch kind {
        case .play: "MessageBrowsePlayFailed"
        case .markFinished: "ToastItemMarkedAsFinishedFailed"
        case .markNotFinished: "ToastItemMarkedAsNotFinishedFailed"
        case .hideFromContinueListening: "MessageBrowseHideFailed"
        case .addToPlaylist, .share, .openDetails: nil
        }
    }
}
