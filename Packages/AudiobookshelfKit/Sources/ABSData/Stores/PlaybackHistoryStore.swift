import ABSCore
import Foundation
import SwiftData

/// The only writer of `PlaybackHistoryEvent` (ADR 0003). History stays on the device.
///
/// Because every write goes through this actor, ``updates(for:)`` sees every change: after each
/// write (or failed, rolled-back write) the store sends a fresh snapshot to every open stream for
/// the media the write touched, or to every stream after a bulk delete.
@ModelActor public actor PlaybackHistoryStore: StoreActor {
    var pendingCommitFailure: (any Error)?
    private var observers: [UUID: Observer] = [:]
    /// Snapshots sent to ``updates(for:)`` streams so far (tests only).
    private(set) var snapshotsSent = 0

    private struct Observer {
        let mediaKey: MediaKey
        let continuation: AsyncStream<[PlaybackHistoryEventDTO]>.Continuation
    }

    /// How long events are kept; older ones are deleted at launch by ``pruneExpired(now:)``.
    public static let retention: TimeInterval = 90 * 24 * 60 * 60

    /// The most events kept per media; the legacy app kept every event forever.
    ///
    /// Beyond the cap, ``record(_:)`` evicts the oldest save and sync events first: playback
    /// saves every 15 seconds, so they would otherwise push out the play, pause, seek, stop and
    /// finished events people look for. Only when no save or sync event is left are the oldest
    /// other events evicted. ``retention`` applies to every event regardless.
    public static let maxEventsPerMedia = 500

    /// Inserts the event, or updates the row with the same `id` in place, then drops the media's
    /// events beyond ``maxEventsPerMedia``.
    ///
    /// - Parameter onlyIfHistoryExists: Records nothing unless the media already has events (the
    ///   legacy rule for sync events). The check and the write happen in one actor call, so no
    ///   other write can delete the history in between.
    /// - Returns: Whether the event was recorded.
    @discardableResult
    public func record(_ event: PlaybackHistoryEventDTO, onlyIfHistoryExists: Bool = false) throws -> Bool {
        if onlyIfHistoryExists, try !hasEvents(for: event.mediaKey) { return false }
        var affected: Set<MediaKey> = [event.mediaKey]
        defer { notifyObservers(of: affected) }
        if let previousKey = try insertOrUpdate(event) {
            affected.insert(previousKey)
        }
        try evictEvents(for: event.mediaKey, keeping: Self.maxEventsPerMedia)
        return true
    }

    /// Returns the media key an updated row had before, when it changed.
    private func insertOrUpdate(_ event: PlaybackHistoryEventDTO) throws -> MediaKey? {
        try commit {
            if let existing = try fetchEvent(id: event.id) {
                let previous = MediaKey(rawValue: existing.mediaKey)
                event.apply(to: existing)
                return previous == event.mediaKey ? nil : previous
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
                return nil
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
        var affected: Set<MediaKey> = []
        defer { notifyObservers(of: affected) }
        return try commit {
            guard let event = try fetchEvent(id: id) else { return false }
            if let key = MediaKey(rawValue: event.mediaKey) {
                affected.insert(key)
            }
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
        defer { notifyObservers(of: [mediaKey]) }
        return try delete(#Predicate { $0.mediaKey == raw })
    }

    /// Deletes every event recorded for media on the connection, for a future "clear history"
    /// action. Removing an account keeps its history (see `ServerConnectionStore.remove(id:now:)`),
    /// so account removal doesn't call this. Returns the number of events deleted.
    @discardableResult
    public func deleteEvents(serverConnectionID: UUID) throws -> Int {
        // Matches on the media key (`<connection>|<item>|<episode>`), which unlike
        // `serverConnectionID` is never optional.
        let prefix = "\(serverConnectionID.uuidString)|"
        defer { notifyObservers(of: nil) }
        return try delete(#Predicate { $0.mediaKey.starts(with: prefix) })
    }

    /// Deletes events older than ``retention``. Returns the number of events deleted.
    @discardableResult
    public func pruneExpired(now: Date = .now) throws -> Int {
        let cutoff = now.addingTimeInterval(-Self.retention)
        defer { notifyObservers(of: nil) }
        return try delete(#Predicate { $0.timestamp < cutoff })
    }

    /// Deletes the media's events beyond `count`, oldest save and sync events first (see
    /// ``maxEventsPerMedia``). Returns the number deleted.
    @discardableResult
    public func pruneEvents(for mediaKey: MediaKey, keeping count: Int = maxEventsPerMedia) throws -> Int {
        defer { notifyObservers(of: [mediaKey]) }
        return try evictEvents(for: mediaKey, keeping: count)
    }

    // MARK: - Private

    @discardableResult
    private func evictEvents(for mediaKey: MediaKey, keeping count: Int) throws -> Int {
        let raw = mediaKey.rawValue
        let save = PlaybackHistoryEventName.save.rawValue
        let sync = PlaybackHistoryEventName.sync.rawValue
        return try commit {
            let total = try modelContext.fetchCount(
                FetchDescriptor<PlaybackHistoryEvent>(predicate: #Predicate { $0.mediaKey == raw })
            )
            let excess = total - max(count, 0)
            guard excess > 0 else { return 0 }
            // Two disjoint sets, so the second fetch never sees rows the first deleted.
            let routine = try oldest(
                excess, #Predicate { $0.mediaKey == raw && ($0.name == save || $0.name == sync) }
            )
            let others = try oldest(
                excess - routine.count, #Predicate { $0.mediaKey == raw && $0.name != save && $0.name != sync }
            )
            for event in routine + others {
                modelContext.delete(event)
            }
            return routine.count + others.count
        }
    }

    private func oldest(_ limit: Int, _ predicate: Predicate<PlaybackHistoryEvent>) throws -> [PlaybackHistoryEvent] {
        guard limit > 0 else { return [] }
        var descriptor = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.timestamp)])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor)
    }

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

    /// Sends a fresh snapshot to the streams for `keys`, or to every stream when `keys` is `nil`
    /// (bulk deletes). Called after failed writes too: they rolled back, so the snapshot shows
    /// the unchanged rows.
    private func notifyObservers(of keys: Set<MediaKey>?) {
        guard !observers.isEmpty else { return }
        var snapshots: [MediaKey: [PlaybackHistoryEventDTO]] = [:]
        for observer in observers.values where keys?.contains(observer.mediaKey) ?? true {
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
                snapshotsSent += 1
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
