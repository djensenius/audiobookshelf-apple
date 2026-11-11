import ABSAPI
import ABSCore
import Foundation
import Observation

/// Library state shared by every scene and CarPlay, keyed by library ID (ADR 0004).
///
/// It holds the libraries list, each library's filter data and media type, and the user's
/// ``progress``, and owns no current library: each scene keeps its own `Router.libraryID` and
/// passes it in. The last-used library per server and user is read from and saved to
/// `AppSettings`.
///
/// The store doesn't watch the signed-in account itself. The app shell wires it up:
/// - when `AccountManager.activeConnection` becomes a connection, call
///   ``connect(client:connectionKey:defaultLibraryID:)`` with that connection's `APIClient`,
///   `LibraryConnectionKey(connectionID:userID:)` and the login's `userDefaultLibraryId`;
/// - when it becomes `nil` (logout), call ``clear()``.
///
/// Connecting a different account clears everything first, including ``progress``, and
/// responses to requests made for an earlier account are dropped. Per-library models
/// (``ItemListModel``, ``PersonalizedShelvesModel``) belong to one account: create them with
/// ``makeItemList(libraryID:query:)`` and ``makeShelves(libraryID:)`` and recreate them when
/// ``connectionKey`` changes (ADR 0004's `.id(identity)`). Other feature models take their
/// service from ``makeServices()`` the same way.
@MainActor
@Observable
public final class LibraryStore {
    /// The account the data belongs to; `nil` when cleared.
    public private(set) var connectionKey: LibraryConnectionKey?
    /// The client for ``connectionKey``.
    public private(set) var client: (any LibraryService)?
    /// The libraries the user can access, in server order.
    public private(set) var libraries: [Library] = []
    /// A refresh has succeeded for this account, so an empty ``libraries`` means there are none.
    public private(set) var hasLoaded = false
    /// Libraries loaded with their filter data, by library ID.
    public private(set) var details: [String: LibraryWithFilterData] = [:]
    public private(set) var isLoading = false
    /// The error of the last libraries refresh, cleared by the next successful one.
    public private(set) var error: (any Error)?
    /// The server's default library for the user (`userDefaultLibraryId` from login).
    public private(set) var defaultLibraryID: String?

    /// The account's server progress; cleared with the store.
    public let progress = ProgressCache()

    @ObservationIgnored private let settings: AppSettings
    /// Bumped by ``clear()``, so responses for an earlier account are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshSequence = 0
    @ObservationIgnored private var detailRequestCount = 0
    /// The latest detail request per library whose response may still be stored. A successful
    /// refresh empties it, so a response requested before the refresh can't bring back a removed
    /// library or an old name.
    @ObservationIgnored private var latestDetailRequests: [String: Int] = [:]
    /// Services already logged as missing from the client, so each is logged once.
    @ObservationIgnored private var loggedUnavailableServices: Set<String> = []

    public init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: Lifecycle

    /// Starts serving `connectionKey`'s account through `client`, then refreshes the libraries.
    /// A different account than the current one clears the store first; the same account
    /// keeps its data while it refreshes, and keeps its ``defaultLibraryID`` when
    /// `defaultLibraryID` is `nil`.
    public func connect(
        client: any LibraryService, connectionKey: LibraryConnectionKey, defaultLibraryID: String? = nil
    ) async {
        if connectionKey != self.connectionKey {
            clear()
            self.connectionKey = connectionKey
        }
        self.client = client
        // Reconnecting the same account (for example with a new client) without a default keeps
        // the one from login; a new account was cleared above.
        if let defaultLibraryID { self.defaultLibraryID = defaultLibraryID }
        await refresh()
    }

    /// Reloads the libraries list. Loaded details take the refreshed libraries (for example a
    /// new name), details of libraries that no longer exist are dropped, and detail loads still
    /// in flight are no longer stored.
    public func refresh() async {
        guard let client else { return }
        let generation = generation
        refreshSequence += 1
        let sequence = refreshSequence
        isLoading = true
        let result: Result<[Library], any Error>
        do {
            result = .success(try await client.libraries())
        } catch {
            result = .failure(error)
        }
        // A newer refresh or a clear owns the state now.
        guard generation == self.generation, sequence == refreshSequence else { return }
        isLoading = false
        switch result {
        case .success(let libraries):
            self.libraries = libraries
            var details: [String: LibraryWithFilterData] = [:]
            for library in libraries {
                guard let loaded = self.details[library.id] else { continue }
                details[library.id] = LibraryWithFilterData(
                    library: library, filterData: loaded.filterData, issues: loaded.issues,
                    numUserPlaylists: loaded.numUserPlaylists)
            }
            self.details = details
            latestDetailRequests = [:]
            hasLoaded = true
            error = nil
        case .failure(let error):
            if !(error is CancellationError) { self.error = error }
        }
    }

    /// Drops all data, progress and the client, for logout or before switching accounts.
    public func clear() {
        generation += 1
        connectionKey = nil
        client = nil
        libraries = []
        hasLoaded = false
        details = [:]
        isLoading = false
        error = nil
        defaultLibraryID = nil
        latestDetailRequests = [:]
        progress.clear()
    }

    // MARK: Libraries

    public func library(id: String) -> Library? {
        libraries.first { $0.id == id } ?? details[id]?.library
    }

    public func mediaType(libraryID: String) -> MediaType? {
        library(id: libraryID)?.mediaType
    }

    public func filterData(libraryID: String) -> LibraryFilterData? {
        details[libraryID]?.filterData
    }

    /// Loads a library with its filter data and stores it under its ID.
    ///
    /// Throws `CancellationError` when the store was cleared or connected to another account
    /// meanwhile, whether the request succeeded or failed. When several loads of the same library overlap, the last one started is kept;
    /// a response to a load started before a successful ``refresh()`` is returned but not stored.
    @discardableResult
    public func loadDetails(libraryID: String) async throws -> LibraryWithFilterData {
        guard let client else { throw CancellationError() }
        let generation = generation
        detailRequestCount += 1
        let request = detailRequestCount
        latestDetailRequests[libraryID] = request
        let loaded: LibraryWithFilterData
        do {
            loaded = try await client.library(id: libraryID)
        } catch {
            // A failure for a cleared account is reported as cancellation, like its response.
            guard generation == self.generation else { throw CancellationError() }
            throw error
        }
        guard generation == self.generation else { throw CancellationError() }
        if latestDetailRequests[libraryID] == request {
            details[libraryID] = loaded
            if let index = libraries.firstIndex(where: { $0.id == loaded.library.id }) {
                libraries[index] = loaded.library
            }
        }
        return loaded
    }

    // MARK: Models

    /// The paged items of a library for the connected account, or `nil` when none is connected.
    /// The model requests through the store's current ``client`` (see ``makeShelves(libraryID:)``).
    public func makeItemList(
        libraryID: String, query: LibraryQuery = LibraryQuery()
    ) -> ItemListModel<LibraryQuery, LibraryItem>? {
        guard client != nil, let connectionKey else { return nil }
        return ItemListModel(
            client: LibraryStoreServices(store: self, connectionKey: connectionKey), libraryID: libraryID, query: query,
            connectionKey: connectionKey)
    }

    /// The home shelves of a library for the connected account, or `nil` when none is connected.
    ///
    /// The model requests through the store's current ``client``, so reconnecting the same
    /// account with a new client (new tokens or server address) retargets it without recreating
    /// it. While the store is cleared or serves another account, its requests fail with
    /// `CancellationError`, and so do responses and failures of requests started before a ``clear()``.
    public func makeShelves(libraryID: String) -> PersonalizedShelvesModel? {
        guard client != nil, let connectionKey else { return nil }
        return PersonalizedShelvesModel(
            client: LibraryStoreServices(store: self, connectionKey: connectionKey), libraryID: libraryID,
            connectionKey: connectionKey)
    }

    /// The services of the connected account for feature models, or `nil` when none is connected.
    ///
    /// Create a screen's model once per account (recreate it when ``connectionKey`` changes) and
    /// pass ``progress`` as its `ProgressCache`:
    ///
    /// ```swift
    /// guard let services = store.makeServices() else { return }
    /// let model = ItemDetailModel(itemID: itemID, service: services, cache: store.progress)
    /// ```
    ///
    /// Requests use the store's current ``client``, so reconnecting the same account with a new
    /// client retargets the model; see ``LibraryStoreServices``.
    public func makeServices() -> LibraryStoreServices? {
        guard client != nil, let connectionKey else { return nil }
        return LibraryStoreServices(store: self, connectionKey: connectionKey)
    }

    /// The store's current client as `Service` and ``clear()`` generation while it still serves
    /// `connectionKey`. Throws ``LibraryStoreError/serviceUnavailable(_:)`` when the client isn't a
    /// `Service`, logging it once per service.
    fileprivate func client<Service>(
        for connectionKey: LibraryConnectionKey, as service: Service.Type
    ) throws -> (client: Service, generation: Int) {
        guard connectionKey == self.connectionKey, let client else { throw CancellationError() }
        guard let client = client as? Service else {
            let name = String(describing: service)
            if loggedUnavailableServices.insert(name).inserted {
                Log.api.error("The library client doesn't implement \(name, privacy: .public)")
            }
            throw LibraryStoreError.serviceUnavailable(name)
        }
        return (client, generation)
    }

    /// Throws unless the store still serves `connectionKey` in `generation`: no ``clear()``,
    /// logout or account switch happened since.
    fileprivate func checkServing(_ connectionKey: LibraryConnectionKey, generation: Int) throws {
        guard connectionKey == self.connectionKey, generation == self.generation else { throw CancellationError() }
    }

    // MARK: Last-used library

    /// The account's last-used library as saved, even if it no longer exists.
    public var lastLibraryID: String? {
        guard let connectionKey else { return nil }
        return settings.lastLibraryID(serverID: connectionKey.serverID, userID: connectionKey.userID)
    }

    /// Saves the account's last-used library; does nothing when no account is connected.
    public func saveLastLibraryID(_ libraryID: String?) {
        guard let connectionKey else { return }
        settings.setLastLibraryID(libraryID, serverID: connectionKey.serverID, userID: connectionKey.userID)
    }

    /// The library a new scene or CarPlay starts in, in the legacy order (`layouts/default.vue`):
    /// the last-used library, then the user's default library, each only if it still exists,
    /// then the first library. Until a refresh succeeds (for example offline) the libraries
    /// aren't known, so the last-used library, or else the default one, is returned unchecked:
    /// callers (the app shell, P3-06) must check `Router.libraryID` against ``libraries`` again
    /// once ``hasLoaded`` becomes `true`.
    public var initialLibraryID: String? {
        guard hasLoaded else { return lastLibraryID ?? defaultLibraryID }
        for candidate in [lastLibraryID, defaultLibraryID] {
            if let candidate, libraries.contains(where: { $0.id == candidate }) { return candidate }
        }
        return libraries.first?.id
    }

    // MARK: View preferences

    /// The account's saved preferences for a library, or `nil` when none are saved, they can't be
    /// read, or no account is connected. Pass them to ``LibraryBrowseModel`` as `stored`.
    public func viewPreferences(libraryID: String) -> LibraryViewPreferences? {
        guard let connectionKey else { return nil }
        return settings.libraryViewPreferences(for: connectionKey, libraryID: libraryID)
    }

    /// Saves the account's preferences for a library, for example as ``LibraryBrowseModel``'s
    /// `persist`; does nothing when no account is connected.
    public func saveViewPreferences(_ preferences: LibraryViewPreferences, libraryID: String) {
        guard let connectionKey else { return }
        settings.saveLibraryViewPreferences(preferences, for: connectionKey, libraryID: libraryID)
    }
}

/// Thrown by ``LibraryStoreServices`` when the store's current client doesn't implement the
/// requested service.
public enum LibraryStoreError: Error, Equatable, Sendable {
    /// The client doesn't conform to the named service protocol, for example `ItemDetailService`.
    case serviceUnavailable(String)
}

/// The services of the account a ``LibraryStore`` serves, for feature models; create it with
/// ``LibraryStore/makeServices()``.
///
/// Each request goes to the store's current client for the account when it starts, so
/// reconnecting the same account with a new client (new tokens or server address) retargets it
/// without recreating the models built on it. While the store is cleared or serves another
/// account, requests throw `CancellationError`, and so do responses and failures of requests
/// started before a ``LibraryStore/clear()``. When the current client doesn't implement the
/// requested service, requests throw ``LibraryStoreError/serviceUnavailable(_:)``.
public struct LibraryStoreServices: LibraryService, ItemDetailService, SearchService, SeriesAuthorsService,
    GroupsService
{
    private weak var store: LibraryStore?
    /// The account the services belong to.
    public let connectionKey: LibraryConnectionKey

    fileprivate init(store: LibraryStore, connectionKey: LibraryConnectionKey) {
        self.store = store
        self.connectionKey = connectionKey
    }

    private func send<Service: Sendable, Response: Sendable>(
        _ service: Service.Type, _ request: (Service) async throws -> Response
    ) async throws -> Response {
        guard let store else { throw CancellationError() }
        let (client, generation) = try await store.client(for: connectionKey, as: service)
        let response: Response
        do {
            response = try await request(client)
        } catch {
            // A failure after a clear or account switch belongs to the previous account: report
            // cancellation instead, so the model doesn't show it.
            try await checkServing(generation: generation)
            throw error
        }
        try await checkServing(generation: generation)
        return response
    }

    private func checkServing(generation: Int) async throws {
        guard let store else { throw CancellationError() }
        try await store.checkServing(connectionKey, generation: generation)
    }

    // MARK: LibraryService

    public func libraries() async throws -> [Library] {
        try await send((any LibraryService).self) { try await $0.libraries() }
    }
    public func library(id: String) async throws -> LibraryWithFilterData {
        try await send((any LibraryService).self) { try await $0.library(id: id) }
    }
    public func personalizedShelves(libraryID: String) async throws -> [Shelf] {
        try await send((any LibraryService).self) { try await $0.personalizedShelves(libraryID: libraryID) }
    }
    public func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem> {
        try await send((any LibraryService).self) { try await $0.items(libraryID: libraryID, query: query) }
    }

    // MARK: ItemDetailService

    public func item(id: String) async throws -> LibraryItem {
        try await send((any ItemDetailService).self) { try await $0.item(id: id) }
    }

    // MARK: SearchService

    public func searchLibrary(id: String, query: String, limit: Int?) async throws -> LibrarySearchResults {
        try await send((any SearchService).self) { try await $0.searchLibrary(id: id, query: query, limit: limit) }
    }

    // MARK: SeriesAuthorsService

    public func seriesPage(libraryID: String, query: LibraryQuery) async throws -> PagedResults<Series> {
        try await send((any SeriesAuthorsService).self) { try await $0.seriesPage(libraryID: libraryID, query: query) }
    }
    public func authorList(libraryID: String) async throws -> [Author] {
        try await send((any SeriesAuthorsService).self) { try await $0.authorList(libraryID: libraryID) }
    }
    public func seriesDetail(id: String) async throws -> SeriesDetailResponse {
        try await send((any SeriesAuthorsService).self) { try await $0.seriesDetail(id: id) }
    }
    public func authorDetail(id: String) async throws -> AuthorDetailResponse {
        try await send((any SeriesAuthorsService).self) { try await $0.authorDetail(id: id) }
    }
    public func filteredBooksPage(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem> {
        try await send((any SeriesAuthorsService).self) {
            try await $0.filteredBooksPage(libraryID: libraryID, query: query)
        }
    }

    // MARK: GroupsService

    public func collectionsPage(libraryID: String, page: Int, limit: Int) async throws -> PagedResults<
        LibraryCollection
    > {
        try await send((any GroupsService).self) {
            try await $0.collectionsPage(libraryID: libraryID, page: page, limit: limit)
        }
    }
    public func playlistsPage(libraryID: String, page: Int, limit: Int) async throws -> PagedResults<Playlist> {
        try await send((any GroupsService).self) {
            try await $0.playlistsPage(libraryID: libraryID, page: page, limit: limit)
        }
    }
    public func collectionDetail(id: String) async throws -> LibraryCollection {
        try await send((any GroupsService).self) { try await $0.collectionDetail(id: id) }
    }
    public func playlistDetail(id: String) async throws -> Playlist {
        try await send((any GroupsService).self) { try await $0.playlistDetail(id: id) }
    }
}
