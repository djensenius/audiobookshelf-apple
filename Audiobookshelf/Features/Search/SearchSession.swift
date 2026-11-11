import ABSAppModel
import ABSCore
import Foundation

/// Which ``SearchModel`` the Search tab shows, and what happens to its query when the account or
/// library changes. Keeps these rules out of the view so they can be tested.
///
/// A model belongs to one store, account and library (ADR 0004). When only the library changes,
/// the new model searches the outgoing query at once, so a library switch (or a `search?q=`
/// link that also switches library) keeps the search. Another store or account starts empty.
@MainActor
struct SearchSession {
    struct Key: Hashable {
        let store: ObjectIdentifier
        let connectionKey: LibraryConnectionKey
        let libraryID: String

        /// Same store and account, whatever the library.
        func isSameAccount(as other: Key) -> Bool {
            store == other.store && connectionKey == other.connectionKey
        }
    }

    /// The key ``model`` was made for; set even when no model could be made.
    private(set) var key: Key?
    /// `nil` without a key, or when the account has no search service.
    private(set) var model: SearchModel?

    /// The key is set but no model could be made for it.
    var isUnavailable: Bool { key != nil && model == nil }

    /// Makes a model for `key` unless it already has one.
    ///
    /// - Parameter makeModel: The model for a key; `nil` when the account can't search.
    /// - Returns: Whether the model was replaced.
    @discardableResult
    mutating func adopt(_ key: Key?, makeModel: (Key) -> SearchModel?) -> Bool {
        guard key != self.key else { return false }
        let previous = (key: self.key, query: model?.query)
        self.key = key
        model = key.flatMap(makeModel)
        if let model, let key, let previousKey = previous.key, previousKey.isSameAccount(as: key),
            let query = previous.query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            model.setQuery(query)
            model.submit()
        }
        return true
    }

    /// A model for `key` searching with `store`'s services, with the library's saved recent
    /// searches. `nil` when `store` isn't connected to `key`'s account.
    static func makeModel(for key: Key, store: LibraryStore, settings: AppSettings?) -> SearchModel? {
        guard store.connectionKey == key.connectionKey, let services = store.makeServices() else { return nil }
        let recents = settings.map { SearchRecentsStore(settings: $0) }
        return SearchModel(
            service: services, libraryID: key.libraryID,
            recentSearches: recents?.recentSearches(connectionKey: key.connectionKey, libraryID: key.libraryID) ?? [],
            persistRecents: recents?.persist(connectionKey: key.connectionKey, libraryID: key.libraryID))
    }

    /// Searches the router's pending `search?q=` query and clears it. Without a model the query
    /// waits in the router.
    func runPendingQuery(from router: Router?) {
        guard let model, let router, let query = router.pendingSearchQuery else { return }
        router.pendingSearchQuery = nil
        model.setQuery(query)
        model.submit()
    }
}
