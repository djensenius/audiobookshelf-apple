import ABSCore
import Foundation
import SwiftData
import Testing

@testable import ABSData

@Suite struct PlaybackHistoryStoreTests {
    private let now = Fixtures.date
    private let key = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_1", episodeId: "ep_1")

    private func makeStore() throws -> PlaybackHistoryStore {
        PlaybackHistoryStore(modelContainer: try DataStack(location: .inMemory).container)
    }

    private func event(
        id: UUID = UUID(), key: MediaKey? = nil, name: PlaybackHistoryEventName = .play, at date: Date
    ) -> PlaybackHistoryEventDTO {
        PlaybackHistoryEventDTO(
            id: id,
            serverConnectionID: Fixtures.connectionID,
            mediaKey: key ?? self.key,
            mediaDisplayTitle: "Episode 1",
            name: name,
            type: .playback,
            details: "details",
            currentTime: 12.5,
            timestamp: date
        )
    }

    @Test func recordsAndReadsEventsNewestFirst() async throws {
        let store = try makeStore()
        let older = event(name: .play, at: now)
        let newer = event(name: .pause, at: now.addingTimeInterval(10))
        let otherMedia = event(key: MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_1"), at: now)
        try await store.record(older)
        try await store.record(newer)
        try await store.record(otherMedia)

        #expect(try await store.events(for: key) == [newer, older])
        #expect(try await store.event(id: older.id) == older)
        #expect(try await store.events(for: otherMedia.mediaKey) == [otherMedia])
    }

    @Test func recordingTheSameIDUpdatesInPlace() async throws {
        let store = try makeStore()
        let id = UUID()
        try await store.record(event(id: id, name: .play, at: now))
        let updated = event(id: id, name: .stop, at: now.addingTimeInterval(1))
        try await store.record(updated)
        #expect(try await store.events(for: key) == [updated])
    }

    @Test func updatesSyncResult() async throws {
        let store = try makeStore()
        let recorded = event(name: .sync, at: now)
        try await store.record(recorded)
        #expect(try await store.updateSyncResult(id: recorded.id, success: false, message: "offline"))
        let synced = try #require(try await store.event(id: recorded.id))
        #expect(synced.serverSyncAttempted)
        #expect(synced.serverSyncSuccess == false)
        #expect(synced.serverSyncMessage == "offline")
        #expect(try await store.updateSyncResult(id: UUID(), success: true, message: nil) == false)
    }

    @Test func deletesEventsForMedia() async throws {
        let store = try makeStore()
        let otherKey = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_9")
        try await store.record(event(at: now))
        try await store.record(event(at: now.addingTimeInterval(1)))
        let kept = event(key: otherKey, at: now)
        try await store.record(kept)

        #expect(try await store.deleteEvents(for: key) == 2)
        #expect(try await store.events(for: key).isEmpty)
        #expect(try await store.events(for: otherKey) == [kept])
        #expect(try await store.deleteEvents(for: key) == 0)
    }

    @Test func pruneExpiredKeepsTheLast90Days() async throws {
        let store = try makeStore()
        let expired = event(at: now.addingTimeInterval(-PlaybackHistoryStore.retention - 1))
        let boundary = event(at: now.addingTimeInterval(-PlaybackHistoryStore.retention))
        let recent = event(at: now)
        for item in [expired, boundary, recent] {
            try await store.record(item)
        }
        #expect(try await store.pruneExpired(now: now) == 1)
        #expect(try await store.events(for: key) == [recent, boundary])
    }

    @Test func pruneExpiredAcrossMediaKeys() async throws {
        let store = try makeStore()
        let book = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_1")
        let other = MediaKey(serverConnectionID: UUID(), libraryItemId: "li_7")
        let old = now.addingTimeInterval(-PlaybackHistoryStore.retention - 60)
        let keptBook = event(key: book, at: now)
        let keptOther = event(key: other, at: now.addingTimeInterval(-60))
        for item in [event(at: old), event(key: book, at: old), event(key: other, at: old), keptBook, keptOther] {
            try await store.record(item)
        }
        #expect(try await store.pruneExpired(now: now) == 3)
        #expect(try await store.events(for: key).isEmpty)
        #expect(try await store.events(for: book) == [keptBook])
        #expect(try await store.events(for: other) == [keptOther])
    }

    @Test func eventsAreLimitedToTheNewest() async throws {
        let store = try makeStore()
        let events = (0..<5).map { event(at: now.addingTimeInterval(Double($0))) }
        for item in events {
            try await store.record(item)
        }
        #expect(try await store.events(for: key, limit: 2) == [events[4], events[3]])
        #expect(try await store.events(for: key).count == 5)
    }

    @Test func recordKeepsTheNewestEventsPerMedia() async throws {
        let store = try makeStore()
        let cap = PlaybackHistoryStore.maxEventsPerMedia
        let other = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_2")
        let otherEvent = event(key: other, at: now.addingTimeInterval(-1))
        try await store.record(otherEvent)
        let events = (0...cap).map { event(at: now.addingTimeInterval(Double($0))) }
        // Oldest last, so the cap applies by timestamp rather than by insertion order.
        for item in events.reversed() {
            try await store.record(item)
        }

        let kept = try await store.events(for: key, limit: cap + 10)
        #expect(kept.count == cap)
        #expect(kept.first == events.last)
        #expect(kept.last == events[1])
        #expect(try await store.event(id: events[0].id) == nil)
        #expect(try await store.events(for: other) == [otherEvent])
    }

    @Test func theCapEvictsSavesBeforePlaybackEvents() async throws {
        let store = try makeStore()
        // 620 events a second apart: 600 saves, with a play or pause every 31st event.
        var playback: [PlaybackHistoryEventDTO] = []
        var saves: [PlaybackHistoryEventDTO] = []
        for index in 0..<620 {
            let date = now.addingTimeInterval(Double(index))
            if index % 31 == 0 {
                let item = event(name: playback.count.isMultiple(of: 2) ? .play : .pause, at: date)
                playback.append(item)
                try await store.record(item)
            } else {
                let item = event(name: .save, at: date)
                saves.append(item)
                try await store.record(item)
            }
        }
        #expect(playback.count == 20)
        #expect(saves.count == 600)

        let kept = try await store.events(for: key, limit: 1_000)
        #expect(kept.count == PlaybackHistoryStore.maxEventsPerMedia)
        #expect(Set(playback.map(\.id)).isSubset(of: Set(kept.map(\.id))))
        let keptSaves = kept.filter { $0.name == .save }.map(\.id)
        #expect(Set(keptSaves) == Set(saves.suffix(480).map(\.id)))
    }

    @Test func pruneEvictsOtherEventsOnceNoSaveOrSyncIsLeft() async throws {
        let store = try makeStore()
        let names: [PlaybackHistoryEventName] = [.save, .play, .sync, .seek, .save, .pause, .stop]
        let events = names.enumerated().map { event(name: $1, at: now.addingTimeInterval(Double($0))) }
        for item in events {
            try await store.record(item)
        }
        // Three saves and syncs go first, then the oldest other event (the play).
        #expect(try await store.pruneEvents(for: key, keeping: 3) == 4)
        #expect(try await store.events(for: key).map(\.name) == [.stop, .pause, .seek])
    }

    @Test func pruneEventsKeepsTheNewest() async throws {
        let store = try makeStore()
        let events = (0..<4).map { event(at: now.addingTimeInterval(Double($0))) }
        for item in events {
            try await store.record(item)
        }
        #expect(try await store.pruneEvents(for: key, keeping: 2) == 2)
        #expect(try await store.events(for: key) == [events[3], events[2]])
        #expect(try await store.pruneEvents(for: key, keeping: 0) == 2)
        #expect(try await store.hasEvents(for: key) == false)
    }

    @Test func deletesEventsForAConnection() async throws {
        let store = try makeStore()
        let removedID = UUID()
        let removedBook = MediaKey(serverConnectionID: removedID, libraryItemId: "li_1")
        let removedEpisode = MediaKey(serverConnectionID: removedID, libraryItemId: "li_2", episodeId: "ep_1")
        try await store.record(event(key: removedBook, at: now))
        try await store.record(event(key: removedEpisode, at: now))
        let kept = event(at: now)
        try await store.record(kept)

        #expect(try await store.deleteEvents(serverConnectionID: removedID) == 2)
        #expect(try await store.hasEvents(for: removedBook) == false)
        #expect(try await store.hasEvents(for: removedEpisode) == false)
        #expect(try await store.events(for: key) == [kept])
        #expect(try await store.deleteEvents(serverConnectionID: removedID) == 0)
    }

    @Test func updatesSendTheCurrentEventsThenEveryChange() async throws {
        let store = try makeStore()
        let first = event(name: .play, at: now)
        try await store.record(first)
        let other = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_2")

        var updates = try await store.updates(for: key).makeAsyncIterator()
        #expect(await updates.next() == [first])

        let second = event(name: .pause, at: now.addingTimeInterval(5))
        try await store.record(second)
        #expect(await updates.next() == [second, first])

        // A write to other media sends nothing: the next snapshot is the sync result's.
        let sent = await store.snapshotsSent
        try await store.record(event(key: other, at: now))
        #expect(await store.snapshotsSent == sent)

        try await store.updateSyncResult(id: second.id, success: true, message: nil)
        let synced = try #require(await updates.next())
        #expect(synced.first?.serverSyncSuccess == true)

        try await store.deleteEvents(for: key)
        #expect(await updates.next() == [])
    }

    @Test func bulkDeletesNotifyEveryStream() async throws {
        let store = try makeStore()
        let first = event(name: .play, at: now)
        try await store.record(first)
        var updates = try await store.updates(for: key).makeAsyncIterator()
        #expect(await updates.next() == [first])

        try await store.deleteEvents(serverConnectionID: Fixtures.connectionID)
        #expect(await updates.next() == [])
    }

    @Test func recordOnlyIfHistoryExistsChecksAndWritesInOneCall() async throws {
        let store = try makeStore()
        let sync = event(name: .sync, at: now)
        #expect(try await store.record(sync, onlyIfHistoryExists: true) == false)
        #expect(try await store.events(for: key).isEmpty)

        let play = event(name: .play, at: now)
        #expect(try await store.record(play))
        let laterSync = event(name: .sync, at: now.addingTimeInterval(10))
        #expect(try await store.record(laterSync, onlyIfHistoryExists: true))
        #expect(try await store.events(for: key) == [laterSync, play])
    }

    @Test(.timeLimit(.minutes(1))) func updatesStopWhenTheConsumerGoesAway() async throws {
        let store = try makeStore()
        let task = Task {
            for await _ in try await store.updates(for: key) {}
        }
        while await store.observerCount == 0 {
            await Task.yield()
        }
        task.cancel()
        _ = await task.result
        while await store.observerCount > 0 {
            await Task.yield()
        }
        #expect(await store.observerCount == 0)
    }

    @Test func failedSaveIsRolledBack() async throws {
        let store = try makeStore()
        let kept = event(at: now)
        try await store.record(kept)
        await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        await #expect(throws: CocoaError.self) { try await store.deleteEvents(for: key) }
        #expect(await store.hasUncommittedChanges == false)
        try await store.record(event(at: now.addingTimeInterval(1)))
        #expect(try await store.events(for: key).count == 2)
    }
}
