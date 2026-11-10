import Foundation
import SwiftData

/// The only writer of `PlaybackHistoryEvent` (ADR 0003). History stays on the device.
@ModelActor public actor PlaybackHistoryStore {
    /// How long events are kept; older ones are deleted at launch by ``pruneExpired(now:)``.
    public static let retention: TimeInterval = 90 * 24 * 60 * 60

    /// Inserts the event, or updates the row with the same `id` in place.
    public func record(_ event: PlaybackHistoryEventDTO) throws {
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
        try modelContext.save()
    }

    public func event(id: UUID) throws -> PlaybackHistoryEventDTO? {
        try fetchEvent(id: id).flatMap(PlaybackHistoryEventDTO.init)
    }

    /// The media's history, newest first (as `pages/media/_id/history.vue` shows it).
    public func events(for mediaKey: MediaKey) throws -> [PlaybackHistoryEventDTO] {
        let raw = mediaKey.rawValue
        let descriptor = FetchDescriptor<PlaybackHistoryEvent>(
            predicate: #Predicate { $0.mediaKey == raw },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).compactMap(PlaybackHistoryEventDTO.init)
    }

    /// Records the outcome of the server sync an event describes. Returns `false` when the event
    /// doesn't exist.
    @discardableResult
    public func updateSyncResult(id: UUID, success: Bool, message: String?) throws -> Bool {
        guard let event = try fetchEvent(id: id) else { return false }
        event.serverSyncAttempted = true
        event.serverSyncSuccess = success
        event.serverSyncMessage = message
        try modelContext.save()
        return true
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
        let count = try modelContext.fetchCount(FetchDescriptor(predicate: predicate))
        guard count > 0 else { return 0 }
        try modelContext.delete(model: PlaybackHistoryEvent.self, where: predicate)
        try modelContext.save()
        return count
    }

    private func fetchEvent(id: UUID) throws -> PlaybackHistoryEvent? {
        var descriptor = FetchDescriptor<PlaybackHistoryEvent>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
