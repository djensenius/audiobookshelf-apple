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
/// ``connectionKey`` changes (ADR 0004's `.id(identity)`).
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
    @ObservationIgnored private var detailSequences: [String: Int] = [:]

    public init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: Lifecycle

    /// Starts serving `connectionKey`'s account through `client`, then refreshes the libraries.
    /// A different account than the current one clears the store first; the same account
    /// keeps its data while it refreshes.
    public func connect(
        client: any LibraryService, connectionKey: LibraryConnectionKey, defaultLibraryID: String? = nil
    ) async {
        if connectionKey != self.connectionKey {
            clear()
            self.connectionKey = connectionKey
        }
        self.client = client
        self.defaultLibraryID = defaultLibraryID
        await refresh()
    }

    /// Reloads the libraries list. Loaded details take the refreshed libraries (for example a
    /// new name), and details of libraries that no longer exist are dropped.
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
        detailSequences = [:]
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
    /// meanwhile. When several loads of the same library overlap, the last one started is kept.
    @discardableResult
    public func loadDetails(libraryID: String) async throws -> LibraryWithFilterData {
        guard let client else { throw CancellationError() }
        let generation = generation
        let sequence = (detailSequences[libraryID] ?? 0) + 1
        detailSequences[libraryID] = sequence
        let loaded = try await client.library(id: libraryID)
        guard generation == self.generation else { throw CancellationError() }
        if detailSequences[libraryID] == sequence {
            details[libraryID] = loaded
            if let index = libraries.firstIndex(where: { $0.id == loaded.library.id }) {
                libraries[index] = loaded.library
            }
        }
        return loaded
    }

    // MARK: Models

    /// The paged items of a library for the connected account, or `nil` when none is connected.
    public func makeItemList(
        libraryID: String, query: LibraryQuery = LibraryQuery()
    ) -> ItemListModel<LibraryQuery, LibraryItem>? {
        guard let client, let connectionKey else { return nil }
        return ItemListModel(client: client, libraryID: libraryID, query: query, connectionKey: connectionKey)
    }

    /// The home shelves of a library for the connected account, or `nil` when none is connected.
    public func makeShelves(libraryID: String) -> PersonalizedShelvesModel? {
        guard let client, let connectionKey else { return nil }
        return PersonalizedShelvesModel(client: client, libraryID: libraryID, connectionKey: connectionKey)
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
    /// aren't known, so the last-used library, or else the default one, is returned unchecked.
    public var initialLibraryID: String? {
        guard hasLoaded else { return lastLibraryID ?? defaultLibraryID }
        for candidate in [lastLibraryID, defaultLibraryID] {
            if let candidate, libraries.contains(where: { $0.id == candidate }) { return candidate }
        }
        return libraries.first?.id
    }
}
