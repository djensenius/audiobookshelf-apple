import Foundation
import SwiftData

/// The only writer of `PlaybackHistoryEvent` (ADR 0003). History stays on the device.
@ModelActor public actor PlaybackHistoryStore: StoreActor {
    var pendingCommitFailure: (any Error)?

    /// How long events are kept; older ones are deleted at launch by ``pruneExpired(now:)``.
    public static let retention: TimeInterval = 90 * 24 * 60 * 60

    /// Inserts the event, or updates the row with the same `id` in place.
    public func record(_ event: PlaybackHistoryEventDTO) throws {
        try commit {
            if let existing = try fetchEvent(id: event.id) {
                event.apply(to: existing)
            } else {
                let model = PlaybackHistoryEvent(
                    id: event.id,
                    serverConnectionID: event.serverConnectionID,
                    mediaKey: event.mediaKey.rawValue,
                    libraryItemId: event.mediaKey.libraryItemId,
                    mediaDisplayTitle: event.mediaDisplayTitle,
                    name: event.name,
                    type: event.type
                )
                event.apply(to: model)
                modelContext.insert(model)
            }
        }
    }

    public func event(id: UUID) throws -> PlaybackHistoryEventDTO? {
        try fetchEvent(id: id).flatMap(PlaybackHistoryEventDTO.init)
    }

    /// The media's newest `limit` events, newest first (as `pages/media/_id/history.vue` shows
    /// them).
    public func events(for mediaKey: MediaKey, limit: Int = 500) throws -> [PlaybackHistoryEventDTO] {
        let raw = mediaKey.rawValue
        var descriptor = FetchDescriptor<PlaybackHistoryEvent>(
            predicate: #Predicate { $0.mediaKey == raw },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap(PlaybackHistoryEventDTO.init)
    }

    /// Records the outcome of the server sync an event describes. Returns `false` when the event
    /// doesn't exist.
    @discardableResult
    public func updateSyncResult(id: UUID, success: Bool, message: String?) throws -> Bool {
        try commit {
            guard let event = try fetchEvent(id: id) else { return false }
            event.serverSyncAttempted = true
            event.serverSyncSuccess = success
            event.serverSyncMessage = message
            return true
        }
    }

    /// Deletes the media's history. Returns the number of events deleted.
    @discardableResult
    public func deleteEvents(for mediaKey: MediaKey) throws -> Int {
        let raw = mediaKey.rawValue
        return try delete(#Predicate { $0.mediaKey == raw })
    }

    /// Deletes events older than ``retention``. Returns the number of events deleted.
    @discardableResult
    public func pruneExpired(now: Date = .now) throws -> Int {
        let cutoff = now.addingTimeInterval(-Self.retention)
        return try delete(#Predicate { $0.timestamp < cutoff })
    }

    // MARK: - Private

    private func delete(_ predicate: Predicate<PlaybackHistoryEvent>) throws -> Int {
        // Row by row: a batch `delete(model:where:)` bypasses the context, so `rollback()`
        // couldn't undo it.
        try commit {
            let events = try modelContext.fetch(FetchDescriptor(predicate: predicate))
            for event in events {
                modelContext.delete(event)
            }
            return events.count
        }
    }

    private func fetchEvent(id: UUID) throws -> PlaybackHistoryEvent? {
        var descriptor = FetchDescriptor<PlaybackHistoryEvent>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
