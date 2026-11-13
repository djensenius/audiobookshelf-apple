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
/// The store doesn't watch the signed-in account itself. ``LibraryParticipant`` wires it to
/// the session lifecycle:
/// - when a session starts or reconnects, it calls ``attach(client:connectionKey:defaultLibraryID:)``
///   with the session's `APIClient`, `LibraryConnectionKey(connectionID:userID:)` and the
///   login's `userDefaultLibraryId`, then ``refresh()`` in a task it owns
///   (``connect(client:connectionKey:defaultLibraryID:)`` does both in one call);
/// - when the session ends (logout or switch), it calls ``clear()``.
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
    /// Bumped each time a client is attached online (a start or a reconnect), so a load that
    /// failed offline can retry. An offline session can keep its client, and then a reconnect
    /// leaves ``connectedKey`` unchanged. Add it to a load's trigger, not to a model's identity:
    /// the account's models stay.
    public private(set) var onlineRevision = 0

    /// The account's server progress; cleared with the store.
    public let progress = ProgressCache()
    /// Whether the session's progress seed may still fill ``progress``: from an online attach
    /// until the seed has settled (``progressSeedBegan()``, ``progressSeedSettled()``). Offline,
    /// without a client and after ``clear()`` nothing is pending.
    public private(set) var isProgressSeedPending = false

    @ObservationIgnored private let settings: AppSettings
    /// Bumped by ``clear()``, so responses for an earlier account are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshSequence = 0
    @ObservationIgnored private var detailRequestCount = 0
    /// The latest detail request per library whose response may still be stored. A successful
    /// refresh empties it, so a response requested before the refresh can't bring back a removed
    /// library or an old name.
    @ObservationIgnored private var latestDetailRequests: [String: Int] = [:]
    /// Readers waiting in ``waitForProgressSeed(timeout:)``.
    @ObservationIgnored private var progressSeedWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Services already logged as missing from the client, so each is logged once.
    @ObservationIgnored private var loggedUnavailableServices: Set<String> = []
    /// Each account's latest shared item actions; see ``itemActions(for:)``. Kept after the
    /// account's session ends, so its next session continues its pending queue.
    @ObservationIgnored private var sharedItemActions: [LibraryConnectionKey: ProgressItemActions] = [:]
    /// Told of each view preferences save (``observeViewPreferences(connectionKey:owner:_:)``).
    @ObservationIgnored private var viewPreferencesObservers: [ViewPreferencesObserver] = []
    /// Told of each socket change (``observeLibraryChanges(connectionKey:owner:_:)``).
    @ObservationIgnored private var libraryChangeObservers: [LibraryChangeObserver] = []

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
        attach(client: client, connectionKey: connectionKey, defaultLibraryID: defaultLibraryID)
        await refresh()
    }

    /// ``connect(client:connectionKey:defaultLibraryID:)`` without the refresh, for callers that
    /// must return promptly and refresh in a task they own (the session's library participant).
    /// A `nil` client (offline without one) serves the account's settings, such as
    /// ``lastLibraryID``, until a later attach brings one. Attaching a client while not
    /// `isOffline` bumps ``onlineRevision``.
    public func attach(
        client: (any LibraryService)?, connectionKey: LibraryConnectionKey, defaultLibraryID: String? = nil,
        isOffline: Bool = false
    ) {
        if connectionKey != self.connectionKey {
            clear()
            self.connectionKey = connectionKey
        }
        self.client = client
        // Reconnecting the same account (for example with a new client) without a default keeps
        // the one from login; a new account was cleared above.
        if let defaultLibraryID { self.defaultLibraryID = defaultLibraryID }
        if client != nil, !isOffline { onlineRevision += 1 }
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

    /// ``connectionKey`` while the store has a client for it, `nil` otherwise. Key a load on it
    /// rather than on ``connectionKey``, so a reconnect that attaches a client to an account
    /// started offline without one retries the load.
    public var connectedKey: LibraryConnectionKey? {
        client == nil ? nil : connectionKey
    }

    /// Whether the store serves `identity`'s account. A scene's shell outlives its account
    /// during a switch, while the store already serves the next one; it must stop reading the
    /// store then.
    public func serves(_ identity: SessionIdentity) -> Bool {
        connectionKey == LibraryConnectionKey(connectionID: identity.connectionID, userID: identity.userID)
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
        progressSeedSettled()
    }

    // MARK: Progress seed

    /// How long ``waitForProgressSeed(timeout:)`` waits by default: past the seed's retries, so
    /// only a seed that hangs is cut short.
    public static let progressSeedTimeout: Duration = .seconds(30)

    /// The seed of an online session is on its way (the session's library participant, at its
    /// online attach).
    public func progressSeedBegan() {
        isProgressSeedPending = true
    }

    /// The seed was applied, dropped or given up, or won't run: waiting readers go on with what
    /// ``progress`` has.
    public func progressSeedSettled() {
        isProgressSeedPending = false
        let waiters = progressSeedWaiters
        progressSeedWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
    }

    /// Returns once no progress seed is pending (at once offline), after `timeout`, or when the
    /// task is cancelled, so what opens at the server's progress (a reader restored with its
    /// window) reads ``progress`` after the seed rather than before it.
    public func waitForProgressSeed(timeout: Duration = progressSeedTimeout) async {
        guard isProgressSeedPending, !Task.isCancelled else { return }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resumeProgressSeedWaiter(id)
        }
        defer { timer.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard isProgressSeedPending, !Task.isCancelled else { return continuation.resume() }
                progressSeedWaiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeProgressSeedWaiter(id) }
        }
    }

    /// `libraryItemID`'s progress in ``progress`` once no seed is pending
    /// (``waitForProgressSeed(timeout:)``).
    public func seededProgress(libraryItemID: String, timeout: Duration = progressSeedTimeout) async -> MediaProgress? {
        await waitForProgressSeed(timeout: timeout)
        return progress.progress(libraryItemID: libraryItemID)
    }

    private func resumeProgressSeedWaiter(_ id: UUID) {
        progressSeedWaiters.removeValue(forKey: id)?.resume()
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

    /// The progress actions (``ProgressItemActions``) for the account the store serves, or `nil`
    /// when it serves none. They change ``progress`` and write through the store's current client
    /// (``LibraryStoreServices``), so a reconnect retargets them; offline without a client, or
    /// after a ``clear()`` or an account switch, a write fails and is rolled back.
    ///
    /// Its per-item queue keeps actions on the same item in order only within one instance, so
    /// screens and windows share the session's ``itemActions(for:)`` instead of building their own.
    public func makeItemActions(localSync: (any ItemActionLocalSync)? = nil) -> ProgressItemActions? {
        guard let connectionKey else { return nil }
        return ProgressItemActions(
            cache: progress, writer: LibraryStoreServices(store: self, connectionKey: connectionKey),
            localSync: localSync)
    }

    /// The one ``ProgressItemActions`` of the account session `connectionKey`, shared by every
    /// window, or `nil` while the store doesn't serve that account. Built on first use and again
    /// once its progress session ended (a ``clear()``, so also a switch or a failed switch's
    /// restart), so a restarted session never acts through the previous one's stale token; an
    /// ordinary reconnect keeps it. A replacement continues the per-item queue of the same
    /// account's previous actions only: another account's progress is independent.
    public func itemActions(for connectionKey: LibraryConnectionKey) -> ProgressItemActions? {
        guard self.connectionKey == connectionKey else { return nil }
        let previous = sharedItemActions[connectionKey]
        if let previous, previous.isCurrentSession { return previous }
        let actions = makeItemActions()
        // A write of the account's ended session may still be in flight: the new actions run after it.
        if let previous { actions?.continueQueue(of: previous) }
        sharedItemActions[connectionKey] = actions
        return actions
    }

    /// Item actions for the account the store serves now, to inject into a window: each action
    /// runs on that account's shared ``itemActions(for:)``, so every window shares one per-item
    /// queue, and fails with `CancellationError` once the store serves another account.
    public func sessionItemActions() -> SessionItemActions? {
        connectionKey.map { SessionItemActions(store: self, connectionKey: $0) }
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

    /// Saves the preferences for a library of `connectionKey`'s account, the one the caller loaded
    /// them for. Does nothing unless the store still serves that account, so a model left over
    /// from before a logout or an account switch can't write into another account. The whole value
    /// is written and the account's observers are told; a model saves only its changes with
    /// ``saveViewPreferences(_:changedFrom:libraryID:connectionKey:)``.
    public func saveViewPreferences(
        _ preferences: LibraryViewPreferences, libraryID: String, connectionKey: LibraryConnectionKey
    ) {
        guard connectionKey == self.connectionKey else { return }
        settings.saveLibraryViewPreferences(preferences, for: connectionKey, libraryID: libraryID)
        notifyViewPreferences(preferences, libraryID: libraryID, connectionKey: connectionKey)
    }

    /// Saves only what a writer changed: the fields that differ between `previous` (what the writer
    /// had) and `preferences` are merged into the latest saved value (or into `previous` when none
    /// is saved), so writers that race keep each other's fields. Like
    /// ``saveViewPreferences(_:libraryID:connectionKey:)``, it does nothing for an account the store
    /// no longer serves, and tells the observers of the account.
    ///
    /// Use it as ``LibraryBrowseModel``'s `persist`, capturing the model's account:
    ///
    /// ```swift
    /// guard let key = store.connectionKey else { return }
    /// let persist: LibraryBrowseModel<Item>.Persist = { [weak store] libraryID, previous, preferences in
    ///     store?.saveViewPreferences(preferences, changedFrom: previous, libraryID: libraryID, connectionKey: key)
    /// }
    /// ```
    public func saveViewPreferences(
        _ preferences: LibraryViewPreferences, changedFrom previous: LibraryViewPreferences, libraryID: String,
        connectionKey: LibraryConnectionKey
    ) {
        guard connectionKey == self.connectionKey else { return }
        let latest = settings.libraryViewPreferences(for: connectionKey, libraryID: libraryID) ?? previous
        saveViewPreferences(
            latest.merging(preferences, from: previous), libraryID: libraryID, connectionKey: connectionKey)
    }

    /// Calls `apply` with a library's saved preferences each time they are saved for
    /// `connectionKey`'s account, by any writer (the observer's own saves included), for as long as
    /// `owner` lives. Live ``LibraryBrowseModel``s observe with
    /// ``LibraryBrowseModel/applySaved(_:libraryID:)``, so one screen's sort or view change shows in
    /// another's model for the same library without rebuilding it.
    public func observeViewPreferences(
        connectionKey: LibraryConnectionKey, owner: AnyObject,
        _ apply: @escaping @MainActor (_ libraryID: String, _ preferences: LibraryViewPreferences) -> Void
    ) {
        viewPreferencesObservers.removeAll { $0.owner == nil }
        viewPreferencesObservers.append(
            ViewPreferencesObserver(owner: owner, connectionKey: connectionKey, apply: apply))
    }

    private func notifyViewPreferences(
        _ preferences: LibraryViewPreferences, libraryID: String, connectionKey: LibraryConnectionKey
    ) {
        viewPreferencesObservers.removeAll { $0.owner == nil }
        for observer in viewPreferencesObservers where observer.connectionKey == connectionKey {
            observer.apply(libraryID, preferences)
        }
    }

    // MARK: Live changes

    /// Hands a socket change from `connectionKey`'s session to that account's observers. Dropped
    /// unless the store serves that account, so a change from an ended or switched session never
    /// reaches another account's models. Wire it as ``RealtimeBridge/onLibraryChange``:
    ///
    /// ```swift
    /// bridge.onLibraryChange = { [weak store] in store?.applyLibraryChange($0, connectionKey: $1) }
    /// ```
    public func applyLibraryChange(_ change: LibraryChange, connectionKey: LibraryConnectionKey) {
        guard connectionKey == self.connectionKey else { return }
        libraryChangeObservers.removeAll { $0.owner == nil }
        for observer in libraryChangeObservers where observer.connectionKey == connectionKey {
            observer.apply(change)
        }
    }

    /// Calls `apply` with each socket change for `connectionKey`'s account, of any library, for as
    /// long as `owner` lives. Models filter by library and entity themselves.
    public func observeLibraryChanges(
        connectionKey: LibraryConnectionKey, owner: AnyObject, _ apply: @escaping @MainActor (LibraryChange) -> Void
    ) {
        libraryChangeObservers.removeAll { $0.owner == nil }
        libraryChangeObservers.append(LibraryChangeObserver(owner: owner, connectionKey: connectionKey, apply: apply))
    }
}

/// An observer of ``LibraryStore``'s saved view preferences, kept while its owner lives.
private struct ViewPreferencesObserver {
    weak var owner: AnyObject?
    let connectionKey: LibraryConnectionKey
    let apply: @MainActor (_ libraryID: String, _ preferences: LibraryViewPreferences) -> Void
}

/// An observer of ``LibraryStore``'s socket changes, kept while its owner lives.
private struct LibraryChangeObserver {
    weak var owner: AnyObject?
    let connectionKey: LibraryConnectionKey
    let apply: @MainActor (LibraryChange) -> Void
}

/// Thrown by ``LibraryStoreServices`` when the store's current client doesn't implement the
/// requested service.
public enum LibraryStoreError: Error, Equatable, Sendable {
    /// The client doesn't conform to the named service protocol, for example `ItemDetailService`.
    case serviceUnavailable(String)
}

/// The server address the client sends requests to, for links to the web client (Share);
/// `APIClient` conforms.
public protocol ServerURLProviding: Sendable {
    func serverURL() async -> URL
}

extension APIClient: ServerURLProviding {
    public func serverURL() -> URL { configuration.baseURL }
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
    GroupsService, LatestEpisodesService
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

    // MARK: LatestEpisodesService

    public func recentEpisodes(libraryID: String, page: Int, limit: Int) async throws -> RecentEpisodesPage {
        try await send((any LatestEpisodesService).self) {
            try await $0.recentEpisodes(libraryID: libraryID, page: page, limit: limit)
        }
    }

    // MARK: Server address (forwarded to the client's ServerURLProviding)

    /// The current client's server address, which follows a reconnect with a new address.
    public func serverURL() async throws -> URL {
        try await send((any ServerURLProviding).self) { await $0.serverURL() }
    }
}

// MARK: PlaylistEditingService

extension LibraryStoreServices: PlaylistEditingService {
    public func allPlaylists(libraryID: String) async throws -> [Playlist] {
        try await send((any PlaylistEditingService).self) { try await $0.allPlaylists(libraryID: libraryID) }
    }
    public func createPlaylist(
        name: String, libraryID: String, items: [PlaylistItemReference]
    ) async throws -> Playlist {
        try await send((any PlaylistEditingService).self) {
            try await $0.createPlaylist(name: name, libraryID: libraryID, items: items)
        }
    }
    public func addToPlaylist(id: String, items: [PlaylistItemReference]) async throws -> Playlist {
        try await send((any PlaylistEditingService).self) { try await $0.addToPlaylist(id: id, items: items) }
    }
    public func removeFromPlaylist(id: String, items: [PlaylistItemReference]) async throws -> Playlist {
        try await send((any PlaylistEditingService).self) { try await $0.removeFromPlaylist(id: id, items: items) }
    }
    public func removeFromPlaylist(id: String, item: PlaylistItemReference) async throws -> Playlist {
        try await send((any PlaylistEditingService).self) { try await $0.removeFromPlaylist(id: id, item: item) }
    }
    public func reorderPlaylist(id: String, items: [PlaylistItemReference]) async throws -> Playlist {
        try await send((any PlaylistEditingService).self) { try await $0.reorderPlaylist(id: id, items: items) }
    }
    public func deletePlaylist(id: String) async throws {
        try await send((any PlaylistEditingService).self) { try await $0.deletePlaylist(id: id) }
    }
}

// MARK: ProgressWriting

/// Lets ``LibraryStore/makeItemActions(localSync:)``'s actions write through the store's current
/// client, so they follow a reconnect and stop at a clear or an account switch.
extension LibraryStoreServices: ProgressWriting {
    public func writeProgress(itemID: String, episodeID: String?, update: MediaProgressUpdate) async throws {
        try await send((any ProgressWriting).self) {
            try await $0.writeProgress(itemID: itemID, episodeID: episodeID, update: update)
        }
    }
    public func progressID(itemID: String, episodeID: String?) async throws -> String? {
        try await send((any ProgressWriting).self) { try await $0.progressID(itemID: itemID, episodeID: episodeID) }
    }
    public func deleteProgress(id: String) async throws {
        try await send((any ProgressWriting).self) { try await $0.deleteProgress(id: id) }
    }
}

// MARK: SessionItemActions

/// A window's item actions for one account: forwards each action to the store's shared
/// ``LibraryStore/itemActions(for:)`` for the account, resolved when the action runs.
public struct SessionItemActions: ItemActionPerforming {
    let store: LibraryStore
    public let connectionKey: LibraryConnectionKey

    private func current() throws -> ProgressItemActions {
        guard let actions = store.itemActions(for: connectionKey) else { throw CancellationError() }
        return actions
    }

    public func markFinished(_ target: ItemActionTarget) async throws {
        try await current().markFinished(target)
    }
    public func markNotFinished(_ target: ItemActionTarget) async throws {
        try await current().markNotFinished(target)
    }
    public func hideFromContinueListening(_ target: ItemActionTarget) async throws {
        try await current().hideFromContinueListening(target)
    }
    public func discardProgress(_ target: ItemActionTarget) async throws {
        try await current().discardProgress(target)
    }
}
