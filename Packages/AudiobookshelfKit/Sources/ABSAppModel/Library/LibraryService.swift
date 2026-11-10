import ABSAPI
import ABSCore
import Foundation

/// The library endpoints the library models use. `APIClient` conforms; tests use fakes.
public protocol LibraryService: Sendable {
    /// `GET /api/libraries`.
    func libraries() async throws -> [Library]
    /// `GET /api/libraries/:id?include=filterdata`.
    func library(id: String) async throws -> LibraryWithFilterData
    /// `GET /api/libraries/:id/personalized`, with shelves that fail to decode skipped.
    func personalizedShelves(libraryID: String) async throws -> [Shelf]
    /// `GET /api/libraries/:id/items`.
    func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem>
}

extension APIClient: LibraryService {
    public func libraries() async throws -> [Library] {
        try await send(LibraryEndpoints.libraries()).libraries
    }

    public func library(id: String) async throws -> LibraryWithFilterData {
        try await send(LibraryEndpoints.library(id: id))
    }

    public func personalizedShelves(libraryID: String) async throws -> [Shelf] {
        try await send(LibraryEndpoints.personalized(libraryID: libraryID)).elements
    }

    public func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem> {
        try await send(LibraryEndpoints.items(libraryID: libraryID, query: query))
    }
}

/// Identifies the signed-in account a ``LibraryStore`` holds data for: a server connection
/// (`ServerConnectionRecord.id`) and the user signed in on it.
public struct LibraryConnectionKey: Sendable, Hashable {
    public var connectionID: UUID
    public var userID: String

    public init(connectionID: UUID, userID: String) {
        self.connectionID = connectionID
        self.userID = userID
    }

    /// The server ID passed to `AppSettings`' last-used library methods.
    public var serverID: String { connectionID.uuidString }
}
