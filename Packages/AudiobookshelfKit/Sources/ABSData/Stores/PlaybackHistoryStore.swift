import ABSCore
import Foundation
import SwiftData

/// The only writer of `PlaybackHistoryEvent` (ADR 0003). History stays on the device.
///
/// Because every write goes through this actor, ``updates(for:)`` sees every change: after each
/// write (or failed, rolled-back write) the store sends a fresh snapshot to every open stream.
@ModelActor public actor PlaybackHistoryStore: StoreActor {
    var pendingCommitFailure: (any Error)?
    private var observers: [UUID: Observer] = [:]

    private struct Observer {
        let mediaKey: MediaKey
        let continuation: AsyncStream<[PlaybackHistoryEventDTO]>.Continuation
    }

    /// How long events are kept; older ones are deleted at launch by ``pruneExpired(now:)``.
    public static let retention: TimeInterval = 90 * 24 * 60 * 60

    /// The most events kept per media. The legacy app kept every event forever; a busy book
    /// saves every 15 seconds, so ``record(_:)`` drops the oldest beyond this. The history page
    /// collapses runs of saves, so 500 events still cover several listening days.
    public static let maxEventsPerMedia = 500

    /// Inserts the event, or updates the row with the same `id` in place, then drops the media's
    /// events beyond ``maxEventsPerMedia``.
    public func record(_ event: PlaybackHistoryEventDTO) throws {
        defer { notifyObservers() }
        try insertOrUpdate(event)
        try pruneEvents(for: event.mediaKey, keeping: Self.maxEventsPerMedia, notify: false)
    }

    private func insertOrUpdate(_ event: PlaybackHistoryEventDTO) throws {
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
    public func events(for mediaKey: MediaKey, limit: Int = maxEventsPerMedia) throws -> [PlaybackHistoryEventDTO] {
        let raw = mediaKey.rawValue
        var descriptor = FetchDescriptor<PlaybackHistoryEvent>(
            predicate: #Predicate { $0.mediaKey == raw },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap(PlaybackHistoryEventDTO.init)
    }

    /// Whether the media has any history.
    public func hasEvents(for mediaKey: MediaKey) throws -> Bool {
        let raw = mediaKey.rawValue
        var descriptor = FetchDescriptor<PlaybackHistoryEvent>(predicate: #Predicate { $0.mediaKey == raw })
        descriptor.fetchLimit = 1
        return try modelContext.fetchCount(descriptor) > 0
    }

    /// The media's events, newest first: the current ones (up to ``maxEventsPerMedia``) right
    /// away, then a new snapshot after every write to the store. Only the newest snapshot is
    /// buffered. The stream ends when the caller stops iterating it.
    public func updates(for mediaKey: MediaKey) throws -> AsyncStream<[PlaybackHistoryEventDTO]> {
        let initial = try events(for: mediaKey)
        let (stream, continuation) = AsyncStream.makeStream(
            of: [PlaybackHistoryEventDTO].self, bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        observers[id] = Observer(mediaKey: mediaKey, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        continuation.yield(initial)
        return stream
    }

    /// The number of open ``updates(for:)`` streams (tests only).
    var observerCount: Int { observers.count }

    /// Records the outcome of the server sync an event describes. Returns `false` when the event
    /// doesn't exist.
    @discardableResult
    public func updateSyncResult(id: UUID, success: Bool, message: String?) throws -> Bool {
        defer { notifyObservers() }
        return try commit {
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

    /// Deletes every event recorded for media on the connection, for when the user removes the
    /// account. Returns the number of events deleted.
    @discardableResult
    public func deleteEvents(serverConnectionID: UUID) throws -> Int {
        // Matches on the media key (`<connection>|<item>|<episode>`), which unlike
        // `serverConnectionID` is never optional.
        let prefix = "\(serverConnectionID.uuidString)|"
        return try delete(#Predicate { $0.mediaKey.starts(with: prefix) })
    }

    /// Deletes events older than ``retention``. Returns the number of events deleted.
    @discardableResult
    public func pruneExpired(now: Date = .now) throws -> Int {
        let cutoff = now.addingTimeInterval(-Self.retention)
        return try delete(#Predicate { $0.timestamp < cutoff })
    }

    /// Deletes the media's events beyond the newest `count`. Returns the number deleted.
    @discardableResult
    public func pruneEvents(for mediaKey: MediaKey, keeping count: Int = maxEventsPerMedia) throws -> Int {
        try pruneEvents(for: mediaKey, keeping: count, notify: true)
    }

    // MARK: - Private

    @discardableResult
    private func pruneEvents(for mediaKey: MediaKey, keeping count: Int, notify: Bool) throws -> Int {
        let raw = mediaKey.rawValue
        var descriptor = FetchDescriptor<PlaybackHistoryEvent>(
            predicate: #Predicate { $0.mediaKey == raw },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchOffset = max(count, 0)
        return try commit(notify: notify) {
            let events = try modelContext.fetch(descriptor)
            for event in events {
                modelContext.delete(event)
            }
            return events.count
        }
    }

    private func delete(_ predicate: Predicate<PlaybackHistoryEvent>) throws -> Int {
        // Row by row: a batch `delete(model:where:)` bypasses the context, so `rollback()`
        // couldn't undo it.
        try commit(notify: true) {
            let events = try modelContext.fetch(FetchDescriptor(predicate: predicate))
            for event in events {
                modelContext.delete(event)
            }
            return events.count
        }
    }

    /// ``commit(_:)``, then a new snapshot for every observer when `notify` is set, even if the
    /// commit failed (it rolled back, so observers see the unchanged rows).
    private func commit<T>(notify: Bool, _ changes: () throws -> T) throws -> T {
        defer { if notify { notifyObservers() } }
        return try commit(changes)
    }

    private func notifyObservers() {
        guard !observers.isEmpty else { return }
        var snapshots: [MediaKey: [PlaybackHistoryEventDTO]] = [:]
        for observer in observers.values {
            if snapshots[observer.mediaKey] == nil {
                do {
                    snapshots[observer.mediaKey] = try events(for: observer.mediaKey)
                } catch {
                    Log.data.error("Couldn't read playback history: \(error.localizedDescription, privacy: .public)")
                    continue
                }
            }
            if let snapshot = snapshots[observer.mediaKey] {
                observer.continuation.yield(snapshot)
            }
        }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func fetchEvent(id: UUID) throws -> PlaybackHistoryEvent? {
        var descriptor = FetchDescriptor<PlaybackHistoryEvent>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
