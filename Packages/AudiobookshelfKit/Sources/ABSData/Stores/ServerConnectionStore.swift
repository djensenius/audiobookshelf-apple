import ABSCore
import Foundation
import SwiftData

/// The only writer of `ServerConnectionRecord` (ADR 0003).
///
/// Connections are looked up by their natural key, the normalized address and the server's user
/// id, so logging in again to a removed connection reuses its `id`: the Keychain entry and every
/// record that refers to it by `serverConnectionID` stay associated.
@ModelActor public actor ServerConnectionStore: StoreActor {
    var pendingCommitFailure: (any Error)?

    /// What ``remove(id:now:)`` did.
    public enum RemovalOutcome: Sendable, Equatable {
        /// The connection had no retained records and was deleted.
        case deleted
        /// The connection still has records that refer to it, so it was kept and marked
        /// disconnected; logging in again reuses it.
        case disconnected
        case notFound
    }

    /// Saves a successful login: updates the connection for `address` and `userId` in place
    /// (clearing `isDisconnected`) or creates one, and marks it as the latest used.
    @discardableResult
    public func upsertLogin(
        address: ServerAddress,
        userId: String,
        username: String,
        authMethod: ServerAuthMethod,
        serverVersion: String?,
        now: Date = .now
    ) throws -> ServerConnectionDTO {
        try commit {
            let record: ServerConnectionRecord
            if let existing = try fetchRecord(address: address.description, userId: userId) {
                record = existing
                record.username = username
                record.authMethod = authMethod.rawValue
                record.serverVersion = serverVersion
            } else {
                record = ServerConnectionRecord(
                    address: address.description,
                    userId: userId,
                    username: username,
                    authMethod: authMethod,
                    serverVersion: serverVersion,
                    createdAt: now
                )
                modelContext.insert(record)
            }
            record.lastUsedAt = now
            record.isDisconnected = false
            record.disconnectedAt = nil
            return ServerConnectionDTO(record)
        }
    }

    public func connection(id: UUID) throws -> ServerConnectionDTO? {
        try fetchRecord(id: id).map(ServerConnectionDTO.init)
    }

    public func connection(address: ServerAddress, userId: String) throws -> ServerConnectionDTO? {
        try fetchRecord(address: address.description, userId: userId).map(ServerConnectionDTO.init)
    }

    /// Every saved connection, most recently used first.
    public func allConnections() throws -> [ServerConnectionDTO] {
        let descriptor = FetchDescriptor<ServerConnectionRecord>(
            sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse), SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map(ServerConnectionDTO.init)
    }

    /// The session to restore at launch: the connected record with the latest `lastUsedAt`.
    public func connectionToRestore() throws -> ServerConnectionDTO? {
        var descriptor = FetchDescriptor<ServerConnectionRecord>(
            predicate: #Predicate { !$0.isDisconnected && $0.lastUsedAt != nil },
            sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map(ServerConnectionDTO.init)
    }

    /// Marks the connection as the latest used (switching servers). Returns `false` when it
    /// doesn't exist.
    @discardableResult
    public func markUsed(id: UUID, at date: Date = .now) throws -> Bool {
        try commit {
            guard let record = try fetchRecord(id: id) else { return false }
            record.lastUsedAt = date
            return true
        }
    }

    @discardableResult
    public func updateServerVersion(id: UUID, _ version: String?) throws -> Bool {
        try commit {
            guard let record = try fetchRecord(id: id) else { return false }
            record.serverVersion = version
            return true
        }
    }

    /// Removes a connection without orphaning its records. A connection with retained records
    /// (progress waiting for sync, pending sessions, download records or downloaded items) is
    /// kept, keeping its `id`, and marked disconnected; any other connection is deleted, and
    /// history rows keep its old id for display. The caller removes the Keychain credentials and
    /// resume-data blobs in both cases.
    ///
    /// The stores' existence checks make a download racing the removal unlikely to orphan
    /// records, but not impossible: `DownloadStore.upsertRecord(_:now:)` and
    /// `LocalItemStore.upsertFromDownload(_:coverUpdatedAt:now:)` throw `connectionNotFound`
    /// once the row is deleted, and a record saved first makes this method keep the row. The
    /// stores check and write through separate contexts, though, so this method can count no
    /// downloads, a record can then be saved, and this method can delete the row, leaving the
    /// record orphaned. Callers must stop the connection's downloads before calling this.
    ///
    /// A disconnected connection whose retained records are later removed is not deleted here.
    /// The cleanup pass (#73) must handle that, and must also catch records whose connection
    /// is gone.
    public func remove(id: UUID, now: Date = .now) throws -> RemovalOutcome {
        try commit {
            guard let record = try fetchRecord(id: id) else { return .notFound }
            if try hasRetainedRecords(connectionID: id) {
                record.isDisconnected = true
                record.disconnectedAt = now
                return .disconnected
            }
            modelContext.delete(record)
            return .deleted
        }
    }

    // MARK: - Private

    private func fetchRecord(id: UUID) throws -> ServerConnectionRecord? {
        var descriptor = FetchDescriptor<ServerConnectionRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchRecord(address: String, userId: String) throws -> ServerConnectionRecord? {
        var descriptor = FetchDescriptor<ServerConnectionRecord>(
            predicate: #Predicate { $0.address == address && $0.userId == userId }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// Reads (never writes) the models other stores own.
    private func hasRetainedRecords(connectionID: UUID) throws -> Bool {
        let progress = FetchDescriptor<LocalMediaProgress>(
            predicate: #Predicate { $0.serverConnectionID == connectionID && $0.needsServerSync }
        )
        let sessions = FetchDescriptor<PendingLocalSession>(
            predicate: #Predicate { $0.serverConnectionID == connectionID }
        )
        let downloads = FetchDescriptor<DownloadRecord>(
            predicate: #Predicate { $0.serverConnectionID == connectionID }
        )
        let items = FetchDescriptor<LocalLibraryItem>(
            predicate: #Predicate { $0.serverConnectionID == connectionID }
        )
        return try modelContext.fetchCount(progress) > 0
            || modelContext.fetchCount(sessions) > 0
            || modelContext.fetchCount(downloads) > 0
            || modelContext.fetchCount(items) > 0
    }
}
