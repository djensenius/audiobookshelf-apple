import Foundation
import SwiftData

/// A streamed session's final `/close` kept to retry (`PendingSessionClose`, #382), as a
/// `Sendable` value.
public struct PendingSessionCloseDTO: Sendable, Equatable {
    public var key: MediaKey
    /// A server capability, not a value to log.
    public var sessionID: String
    public var currentTime: Double
    /// The listening time no acknowledged report carried.
    public var timeListened: Double
    public var duration: Double
    /// The audio edit time the close's own position committed with; `nil` when it never did.
    public var positionEditedAt: Date?
    public var capturedAt: Date
    /// The latest attempt that may have reached the server; `nil` when none could have.
    public var lastAttemptAt: Date?
    public var attempts: Int

    public init(
        key: MediaKey, sessionID: String, currentTime: Double, timeListened: Double, duration: Double,
        positionEditedAt: Date?, capturedAt: Date, lastAttemptAt: Date? = nil, attempts: Int = 0
    ) {
        self.key = key
        self.sessionID = sessionID
        self.currentTime = currentTime
        self.timeListened = timeListened
        self.duration = duration
        self.positionEditedAt = positionEditedAt
        self.capturedAt = capturedAt
        self.lastAttemptAt = lastAttemptAt
        self.attempts = attempts
    }

    init(_ model: PendingSessionClose) {
        self.init(
            key: MediaKey(
                serverConnectionID: model.serverConnectionID, libraryItemId: model.libraryItemId,
                episodeId: model.episodeId),
            sessionID: model.sessionID, currentTime: model.currentTime, timeListened: model.timeListened,
            duration: model.duration, positionEditedAt: model.positionEditedAt, capturedAt: model.capturedAt,
            lastAttemptAt: model.lastAttemptAt, attempts: model.attempts)
    }
}

/// The close queue: `LocalProgressStore` is the only writer of `PendingSessionClose`.
extension LocalProgressStore {
    /// Inserts or replaces the close for `close.key`'s connection and `close.sessionID`.
    public func saveSessionClose(_ close: PendingSessionCloseDTO) throws {
        try commit {
            if let model = try fetchSessionClose(
                serverConnectionID: close.key.serverConnectionID, sessionID: close.sessionID)
            {
                model.libraryItemId = close.key.libraryItemId
                model.episodeId = close.key.episodeId
                model.currentTime = close.currentTime
                model.timeListened = close.timeListened
                model.duration = close.duration
                model.positionEditedAt = close.positionEditedAt
                model.capturedAt = close.capturedAt
                model.lastAttemptAt = close.lastAttemptAt
                model.attempts = close.attempts
            } else {
                modelContext.insert(
                    PendingSessionClose(
                        serverConnectionID: close.key.serverConnectionID, sessionID: close.sessionID,
                        libraryItemId: close.key.libraryItemId, episodeId: close.key.episodeId,
                        currentTime: close.currentTime, timeListened: close.timeListened, duration: close.duration,
                        positionEditedAt: close.positionEditedAt, capturedAt: close.capturedAt,
                        lastAttemptAt: close.lastAttemptAt, attempts: close.attempts))
            }
        }
    }

    /// The connection's closes, oldest capture first.
    public func sessionCloses(for connectionID: UUID) throws -> [PendingSessionCloseDTO] {
        let descriptor = FetchDescriptor<PendingSessionClose>(
            predicate: #Predicate { $0.serverConnectionID == connectionID },
            sortBy: [SortDescriptor(\.capturedAt), SortDescriptor(\.sessionID)])
        return try modelContext.fetch(descriptor).map(PendingSessionCloseDTO.init)
    }

    /// Saves `attemptAt` as the close's latest attempt only if the stored close is still `read`,
    /// in one turn of the store: a capture that settled the close since (removed it, or kept it
    /// with a new attempt), in any playback scope sharing this store, wins. Returns whether the
    /// attempt was saved.
    public func claimSessionCloseAttempt(_ read: PendingSessionCloseDTO, at attemptAt: Date) throws -> Bool {
        guard
            let model = try fetchSessionClose(
                serverConnectionID: read.key.serverConnectionID, sessionID: read.sessionID),
            PendingSessionCloseDTO(model) == read
        else { return false }
        try commit { model.lastAttemptAt = attemptAt }
        return true
    }

    /// Removes the close; nothing to remove is not an error.
    public func deleteSessionClose(serverConnectionID: UUID, sessionID: String) throws {
        try commit {
            if let model = try fetchSessionClose(serverConnectionID: serverConnectionID, sessionID: sessionID) {
                modelContext.delete(model)
            }
        }
    }

    private func fetchSessionClose(serverConnectionID: UUID, sessionID: String) throws -> PendingSessionClose? {
        var descriptor = FetchDescriptor<PendingSessionClose>(
            predicate: #Predicate { $0.serverConnectionID == serverConnectionID && $0.sessionID == sessionID })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
