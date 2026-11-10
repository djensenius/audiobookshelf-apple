import ABSAPI
import ABSCore
import Foundation
import Observation

/// Library state shared by every scene and CarPlay, keyed by library ID (ADR 0004).
///
/// It holds the libraries list and each library's filter data and media type, and owns no
/// current library: each scene keeps its own `Router.libraryID` and passes it in. The
/// last-used library per server and user is read from and saved to `AppSettings`.
///
/// The store doesn't watch the signed-in account itself. The app shell wires it up:
/// - when `AccountManager.activeConnection` becomes a connection, call
///   ``connect(client:connectionKey:)`` with that connection's `APIClient` and
///   `LibraryConnectionKey(connectionID:userID:)`;
/// - when it becomes `nil` (logout), call ``clear()``.
///
/// Connecting a different account clears everything first, and responses to requests made
/// for an earlier account are dropped.
@MainActor
@Observable
public final class LibraryStore {
    /// The account the data belongs to; `nil` when cleared.
    public private(set) var connectionKey: LibraryConnectionKey?
    /// The libraries the user can access, in server order.
    public private(set) var libraries: [Library] = []
    /// Libraries loaded with their filter data, by library ID.
    public private(set) var details: [String: LibraryWithFilterData] = [:]
    public private(set) var isLoading = false
    /// The error of the last libraries refresh, cleared by the next successful one.
    public private(set) var error: (any Error)?

    /// The client for ``connectionKey``; models such as ``ItemListModel`` use it.
    @ObservationIgnored public private(set) var client: (any LibraryService)?
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
    public func connect(client: any LibraryService, connectionKey: LibraryConnectionKey) async {
        if connectionKey != self.connectionKey {
            clear()
            self.connectionKey = connectionKey
        }
        self.client = client
        await refresh()
    }

    /// Reloads the libraries list. Filter data of libraries that no longer exist is dropped.
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
            let ids = Set(libraries.map(\.id))
            details = details.filter { ids.contains($0.key) }
            error = nil
        case .failure(let error):
            if !(error is CancellationError) { self.error = error }
        }
    }

    /// Drops all data and the client, for logout or before switching accounts.
    public func clear() {
        generation += 1
        connectionKey = nil
        client = nil
        libraries = []
        details = [:]
        isLoading = false
        error = nil
        detailSequences = [:]
    }

    // MARK: Libraries

    public func library(id: String) -> Library? {
        details[id]?.library ?? libraries.first { $0.id == id }
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

    /// The library a new scene or CarPlay starts in: the last-used library if it still exists,
    /// otherwise the first library.
    public var initialLibraryID: String? {
        if let lastLibraryID, libraries.contains(where: { $0.id == lastLibraryID }) {
            return lastLibraryID
        }
        return libraries.first?.id
    }
}
