import ABSCore
import Foundation
import SwiftData
import Testing

@testable import ABSData

@Suite struct DownloadStoreTests {
    private let now = Fixtures.date
    private let key = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_2", episodeId: "ep_1")

    private func makeStore() throws -> (DownloadStore, ModelContainer) {
        let container = try DataStack(location: .inMemory).container
        return (DownloadStore(modelContainer: container), container)
    }

    static func part(
        id: UUID = UUID(), kind: DownloadPartKind = .audio, trackIndex: Int? = 1, filename: String = "ep1.mp3",
        state: DownloadPartState = .queued
    ) -> DownloadPartDTO {
        DownloadPartDTO(
            id: id,
            kind: kind,
            serverPath: "/api/items/li_2/file/13/download",
            filename: filename,
            mimeType: kind == .cover ? "image/jpeg" : "audio/mpeg",
            serverIno: "13",
            trackIndex: trackIndex,
            episodeId: kind == .cover ? nil : "ep_1",
            expectedBytes: 3_000_000_000,
            destinationRelativePath: "li_2/\(filename)",
            state: state
        )
    }

    static func record(
        key: MediaKey, title: String = "Episode 1", parts: [DownloadPartDTO], state: DownloadState = .queued
    ) -> DownloadRecordDTO {
        DownloadRecordDTO(
            key: key,
            mediaType: .podcast,
            title: title,
            state: state,
            relativeDirectory: "li_2",
            media: Fixtures.podcastSnapshot,
            parts: parts
        )
    }

    @Test func createsAndReadsRecordWithOrderedParts() async throws {
        let (store, _) = try makeStore()
        let cover = Self.part(kind: .cover, trackIndex: nil, filename: "cover.jpg")
        let track2 = Self.part(trackIndex: 2, filename: "b.mp3")
        let track1 = Self.part(trackIndex: 1, filename: "a.mp3")
        let created = try await store.upsertRecord(Self.record(key: key, parts: [cover, track2, track1]), now: now)

        #expect(created.key == key)
        #expect(created.createdAt == now)
        #expect(created.updatedAt == now)
        #expect(created.media == Fixtures.podcastSnapshot)
        #expect(created.parts == [track1, track2, cover])
        #expect(try await store.record(id: created.id) == created)
        #expect(try await store.record(key: key) == created)
        #expect(try await store.part(id: track2.id) == track2)
    }

    @Test func upsertSameKeyKeepsIDAndReconcilesParts() async throws {
        let (store, container) = try makeStore()
        let kept = Self.part(trackIndex: 1, filename: "a.mp3")
        let dropped = Self.part(trackIndex: 2, filename: "b.mp3")
        let first = try await store.upsertRecord(Self.record(key: key, parts: [kept, dropped]), now: now)

        var keptUpdate = kept
        keptUpdate.bytesWritten = 42
        let added = Self.part(trackIndex: 3, filename: "c.mp3")
        var input = Self.record(key: key, title: "Renamed", parts: [keptUpdate, added], state: .downloading)
        input.id = UUID()
        let later = now.addingTimeInterval(5)
        let second = try await store.upsertRecord(input, now: later)

        #expect(second.id == first.id)
        #expect(second.createdAt == now)
        #expect(second.updatedAt == later)
        #expect(second.title == "Renamed")
        #expect(second.state == .downloading)
        #expect(second.parts == [keptUpdate, added])
        #expect(try await store.allRecords().count == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<DownloadPart>()) == 2)
    }

    @Test func queriesByStateConnectionAndCompletion() async throws {
        let (store, _) = try makeStore()
        let otherConnection = UUID()
        let done = try await store.upsertRecord(
            Self.record(key: key, parts: [Self.part(state: .completed)], state: .downloading), now: now)
        let queued = try await store.upsertRecord(
            Self.record(
                key: MediaKey(serverConnectionID: otherConnection, libraryItemId: "li_3"), parts: [Self.part()]),
            now: now.addingTimeInterval(1))
        let empty = try await store.upsertRecord(
            Self.record(key: MediaKey(serverConnectionID: otherConnection, libraryItemId: "li_4"), parts: []),
            now: now.addingTimeInterval(2))

        #expect(try await store.allRecords().map(\.id) == [done.id, queued.id, empty.id])
        #expect(try await store.records(state: .downloading).map(\.id) == [done.id])
        #expect(try await store.records(state: .queued).map(\.id) == [queued.id, empty.id])
        #expect(try await store.records(serverConnectionID: otherConnection).map(\.id) == [queued.id, empty.id])
        #expect(try await store.completedRecords().map(\.id) == [done.id])
    }

    @Test func updatesPartAndRecordState() async throws {
        let (store, _) = try makeStore()
        let part = Self.part()
        let created = try await store.upsertRecord(Self.record(key: key, parts: [part]), now: now)

        var running = part
        running.state = .running
        running.taskIdentifier = 7
        running.bytesWritten = 1_000
        running.hasResumeData = true
        let later = now.addingTimeInterval(3)
        #expect(try await store.updatePart(running, now: later))
        #expect(try await store.part(taskIdentifier: 7) == running)
        #expect(try await store.part(taskIdentifier: 8) == nil)
        #expect(try await store.record(id: created.id)?.updatedAt == later)
        #expect(try await store.updatePart(Self.part()) == false)

        #expect(try await store.setState(.paused, forRecord: created.id, now: later))
        #expect(try await store.record(id: created.id)?.state == .paused)
        #expect(try await store.setState(.paused, forRecord: UUID()) == false)
    }

    @Test func deleteRecordCascadesToPartsOnly() async throws {
        let (store, container) = try makeStore()
        let created = try await store.upsertRecord(
            Self.record(key: key, parts: [Self.part(), Self.part(trackIndex: 2, filename: "b.mp3")]), now: now)
        let other = try await store.upsertRecord(
            Self.record(
                key: MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_9"),
                parts: [Self.part(filename: "z.mp3")]), now: now)
        let context = ModelContext(container)
        context.insert(Fixtures.progress())
        try context.save()

        let deleted = try await store.deleteRecord(created.id)
        #expect(deleted == created)
        #expect(try await store.record(id: created.id) == nil)
        #expect(try await store.deleteRecord(created.id) == nil)
        #expect(try await store.record(id: other.id) == other)
        #expect(try context.fetchCount(FetchDescriptor<DownloadPart>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<LocalMediaProgress>()) == 1)
    }
}
