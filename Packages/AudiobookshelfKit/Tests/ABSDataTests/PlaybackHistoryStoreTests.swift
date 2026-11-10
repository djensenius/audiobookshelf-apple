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
}
