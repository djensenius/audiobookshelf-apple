import ABSCore
import Foundation
import SwiftData
import Testing

@testable import ABSData

/// Every `#Unique` in SchemaV1, the `.codable` attributes and the cascade relationships.
@Suite struct SchemaV1Tests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try DataStack(location: .inMemory).container)
    }

    /// Inserts `first`, saves, inserts `second` with the same unique key and saves again.
    private func insertDuplicate<Model: PersistentModel>(
        _ first: Model,
        _ second: Model,
        in context: ModelContext
    ) throws -> [Model] {
        context.insert(first)
        try context.save()
        context.insert(second)
        try context.save()
        return try context.fetch(FetchDescriptor<Model>())
    }

    // MARK: - #Unique

    @Test func serverConnectionIDIsUnique() throws {
        let id = UUID()
        let rows = try insertDuplicate(
            Fixtures.connection(id: id, userId: "usr_1"),
            Fixtures.connection(id: id, userId: "usr_2"),
            in: try makeContext()
        )
        #expect(rows.count == 1)
    }

    @Test func serverConnectionAddressAndUserAreUnique() throws {
        let second = UUID()
        let rows = try insertDuplicate(
            Fixtures.connection(id: UUID()),
            Fixtures.connection(id: second),
            in: try makeContext()
        )
        // SwiftData resolves the conflict by replacing the row, including its `id`; this is why
        // stores fetch by the natural key and update in place instead of relying on `#Unique`.
        #expect(rows.map(\.id) == [second])
    }

    @Test func connectionsForOtherUsersOrAddressesAreDistinct() throws {
        let context = try makeContext()
        context.insert(Fixtures.connection(address: "https://abs.example.com", userId: "usr_1"))
        context.insert(Fixtures.connection(address: "https://abs.example.com", userId: "usr_2"))
        context.insert(Fixtures.connection(address: "https://abs.example.com/sub", userId: "usr_1"))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<ServerConnectionRecord>()) == 3)
    }

    @Test func localLibraryItemIDIsUnique() throws {
        let id = UUID()
        let rows = try insertDuplicate(
            Fixtures.item(id: id, libraryItemId: "li_1"),
            Fixtures.item(id: id, libraryItemId: "li_9"),
            in: try makeContext()
        )
        #expect(rows.count == 1)
    }

    @Test func localLibraryItemConnectionAndLibraryItemAreUnique() throws {
        let rows = try insertDuplicate(
            Fixtures.item(title: "First"),
            Fixtures.item(title: "Second"),
            in: try makeContext()
        )
        #expect(rows.map(\.title) == ["Second"])
    }

    @Test func localFileIDIsUnique() throws {
        let id = UUID()
        let rows = try insertDuplicate(
            Fixtures.file(id: id, trackIndex: 1),
            Fixtures.file(id: id, trackIndex: 2),
            in: try makeContext()
        )
        #expect(rows.map(\.trackIndex) == [2])
    }

    @Test func localMediaProgressKeyIsUnique() throws {
        let rows = try insertDuplicate(
            Fixtures.progress(currentTime: 10),
            Fixtures.progress(currentTime: 20),
            in: try makeContext()
        )
        #expect(rows.map(\.currentTime) == [20])
    }

    @Test func progressForEpisodesOfOneItemIsDistinct() throws {
        let context = try makeContext()
        context.insert(Fixtures.progress(key: Fixtures.mediaKey("li_1")))
        context.insert(Fixtures.progress(key: Fixtures.mediaKey("li_1", episodeId: "ep_1")))
        context.insert(Fixtures.progress(key: Fixtures.mediaKey("li_1", episodeId: "ep_2")))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<LocalMediaProgress>()) == 3)
    }

    @Test func downloadRecordIDIsUnique() throws {
        let id = UUID()
        let rows = try insertDuplicate(
            Fixtures.download(id: id, key: Fixtures.mediaKey("li_2")),
            Fixtures.download(id: id, key: Fixtures.mediaKey("li_3")),
            in: try makeContext()
        )
        #expect(rows.count == 1)
    }

    @Test func downloadRecordKeyIsUnique() throws {
        let rows = try insertDuplicate(
            Fixtures.download(title: "First"),
            Fixtures.download(title: "Second"),
            in: try makeContext()
        )
        #expect(rows.map(\.title) == ["Second"])
    }

    @Test func downloadPartIDIsUnique() throws {
        let id = UUID()
        let second = Fixtures.part(id: id)
        second.bytesWritten = 2_000
        let rows = try insertDuplicate(Fixtures.part(id: id), second, in: try makeContext())
        #expect(rows.map(\.bytesWritten) == [2_000])
    }

    @Test func pendingLocalSessionIDIsUnique() throws {
        let rows = try insertDuplicate(
            Fixtures.session(id: "session-1", currentTime: 10),
            Fixtures.session(id: "session-1", currentTime: 30),
            in: try makeContext()
        )
        #expect(rows.map(\.currentTime) == [30])
    }

    @Test func playbackHistoryEventIDIsUnique() throws {
        let id = UUID()
        let rows = try insertDuplicate(
            Fixtures.historyEvent(id: id, name: .play),
            Fixtures.historyEvent(id: id, name: .pause),
            in: try makeContext()
        )
        #expect(rows.map(\.nameValue) == [.pause])
    }

    // MARK: - Round trips

    @Test func codableAttributesRoundTripOnDisk() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Audiobookshelf.store")

        let baseline = ProgressBaseline(
            currentTime: 100,
            progress: 0.25,
            duration: 400,
            isFinished: false,
            ebookLocation: "epubcfi(/6/4)",
            ebookProgress: 0.1,
            lastUpdate: Fixtures.date
        )
        let sends = (0..<ProgressSend.historyLimit).map { index in
            ProgressSend(
                audio: .init(
                    currentTime: Double(index),
                    progress: 0.5,
                    duration: 400,
                    editedAt: Fixtures.date.addingTimeInterval(Double(index))
                ),
                finished: index.isMultiple(of: 2)
                    ? .init(isFinished: true, finishedAt: Fixtures.date, editedAt: Fixtures.date) : nil,
                ebook: index == 3 ? .init(ebookLocation: nil, ebookProgress: 0.9, editedAt: Fixtures.date) : nil
            )
        }

        do {
            let context = ModelContext(try DataStack(location: .url(url)).container)
            let item = Fixtures.item()
            context.insert(item)
            item.files.append(Fixtures.file())
            let progress = Fixtures.progress()
            progress.serverBaseline = baseline
            progress.unacknowledgedSends = sends
            progress.sendHistoryTruncated = true
            progress.audioDirty = true
            progress.audioEditedAt = Fixtures.date
            progress.needsServerSync = true
            context.insert(progress)
            let download = Fixtures.download()
            context.insert(download)
            download.parts.append(Fixtures.part())
            try context.save()
        }

        let context = ModelContext(try DataStack(location: .url(url)).container)
        let item = try #require(try context.fetch(FetchDescriptor<LocalLibraryItem>()).first)
        #expect(item.media == Fixtures.bookSnapshot)
        #expect(item.coverUpdatedAt == Fixtures.date)
        #expect(item.mediaTypeValue == .book)
        #expect(item.files.first?.size == 5_000_000_000)
        #expect(item.files.first?.kindValue == .audio)

        let progress = try #require(try context.fetch(FetchDescriptor<LocalMediaProgress>()).first)
        #expect(progress.serverBaseline == baseline)
        #expect(progress.unacknowledgedSends == sends)
        #expect(progress.sendHistoryTruncated)
        #expect(progress.audioDirty && !progress.finishedDirty && !progress.ebookDirty)
        #expect(progress.audioEditedAt == Fixtures.date)

        let download = try #require(try context.fetch(FetchDescriptor<DownloadRecord>()).first)
        #expect(download.media == Fixtures.podcastSnapshot)
        #expect(download.stateValue == .downloading)
        #expect(download.mediaTypeValue == .podcast)
        let part = try #require(download.parts.first)
        #expect(part.kindValue == .audio)
        #expect(part.stateValue == .running)
        #expect(part.expectedBytes == 3_000_000_000)
        #expect(part.taskIdentifier == 42)
        #expect(part.hasResumeData)
    }

    @Test func emptyCodableValuesRoundTrip() throws {
        let context = try makeContext()
        context.insert(Fixtures.progress())
        try context.save()

        let fresh = ModelContext(context.container)
        let progress = try #require(try fresh.fetch(FetchDescriptor<LocalMediaProgress>()).first)
        #expect(progress.serverBaseline == nil)
        #expect(progress.unacknowledgedSends.isEmpty)
        #expect(!progress.needsServerSync)
    }

    @Test func pendingSyncQueryUsesStoredFlag() throws {
        let context = try makeContext()
        let dirty = Fixtures.progress(key: Fixtures.mediaKey("li_1"))
        dirty.ebookDirty = true
        dirty.needsServerSync = true
        context.insert(dirty)
        context.insert(Fixtures.progress(key: Fixtures.mediaKey("li_2")))
        try context.save()

        let pending = try context.fetch(
            FetchDescriptor<LocalMediaProgress>(predicate: #Predicate { $0.needsServerSync }))
        #expect(pending.map(\.key) == [Fixtures.mediaKey("li_1")])
    }

    @Test func rawValueAccessorsMapStoredStrings() throws {
        let context = try makeContext()
        let connection = Fixtures.connection()
        let event = Fixtures.historyEvent(name: .finished)
        let session = Fixtures.session()
        context.insert(connection)
        context.insert(event)
        context.insert(session)
        try context.save()

        #expect(connection.authMethod == "openid")
        #expect(connection.authMethodValue == .openid)
        #expect(event.name == "Finished")
        #expect(event.typeValue == .playback)
        #expect(session.mediaTypeValue == .book)
        #expect(session.playMethod == PendingLocalSession.localPlayMethod)

        connection.authMethod = "unknown"
        #expect(connection.authMethodValue == nil)
    }

    // MARK: - Relationships

    @Test func deletingItemCascadesToFilesOnly() throws {
        let context = try makeContext()
        let item = Fixtures.item()
        context.insert(item)
        item.files.append(contentsOf: [Fixtures.file(trackIndex: 1), Fixtures.file(trackIndex: 2)])
        context.insert(Fixtures.progress())
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<LocalFile>()) == 2)
        #expect(item.files.allSatisfy { $0.item === item })

        context.delete(item)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<LocalFile>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<LocalMediaProgress>()) == 1)
    }

    @Test func deletingDownloadCascadesToParts() throws {
        let context = try makeContext()
        let download = Fixtures.download()
        context.insert(download)
        download.parts.append(contentsOf: [Fixtures.part(), Fixtures.part()])
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<DownloadPart>()) == 2)

        context.delete(download)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<DownloadPart>()) == 0)
    }
}
