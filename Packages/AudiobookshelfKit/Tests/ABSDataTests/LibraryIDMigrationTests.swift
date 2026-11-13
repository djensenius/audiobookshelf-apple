import ABSCore
import Foundation
import SwiftData
import Testing

@testable import ABSData

/// `SchemaV1` as it was before downloads recorded their library (#571): `LocalLibraryItem` and
/// `DownloadRecord` without `libraryId`, and the files and parts related to them. Frozen; the
/// other models are unchanged, so they are `SchemaV1`'s.
private enum PreLibraryIDSchema: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [
            SchemaV1.ServerConnectionRecord.self, LocalLibraryItem.self, LocalFile.self,
            SchemaV1.LocalMediaProgress.self, DownloadRecord.self, DownloadPart.self,
            SchemaV1.PendingLocalSession.self, SchemaV1.PlaybackHistoryEvent.self, SchemaV1.PendingSessionClose.self,
        ]
    }

    @Model final class LocalLibraryItem {
        #Unique<LocalLibraryItem>([\.id], [\.serverConnectionID, \.libraryItemId])
        #Index<LocalLibraryItem>([\.libraryItemId], [\.serverConnectionID])

        var id: UUID
        var serverConnectionID: UUID
        var serverAddress: String
        var serverUserId: String
        var libraryItemId: String
        var mediaType: String
        var title: String
        var authorName: String?
        var relativeDirectory: String
        var coverRelativePath: String?
        var coverUpdatedAt: Date?
        var addedAt: Date
        var updatedAt: Date
        @Attribute(.codable) var media: LocalMediaSnapshot
        @Relationship(deleteRule: .cascade, inverse: \LocalFile.item) var files: [LocalFile]

        init(serverConnectionID: UUID, libraryItemId: String) {
            id = UUID()
            self.serverConnectionID = serverConnectionID
            serverAddress = "https://abs.example.com"
            serverUserId = "usr_1"
            self.libraryItemId = libraryItemId
            mediaType = MediaType.book.rawValue
            title = "The Book"
            relativeDirectory = libraryItemId
            addedAt = Fixtures.date
            updatedAt = Fixtures.date
            media = Fixtures.bookSnapshot
            files = []
        }
    }

    @Model final class LocalFile {
        #Unique<LocalFile>([\.id])

        var id: UUID
        var item: LocalLibraryItem?
        var kind: String
        var relativePath: String
        var filename: String
        var mimeType: String
        var size: Int64
        var serverIno: String?
        var trackIndex: Int?
        var episodeId: String?

        init(relativePath: String) {
            id = UUID()
            kind = LocalFileKind.audio.rawValue
            self.relativePath = relativePath
            filename = (relativePath as NSString).lastPathComponent
            mimeType = "audio/mpeg"
            size = 100
            trackIndex = 1
        }
    }

    @Model final class DownloadRecord {
        #Unique<DownloadRecord>([\.id], [\.key])
        #Index<DownloadRecord>([\.state])

        var id: UUID
        var key: String
        var serverConnectionID: UUID
        var libraryItemId: String
        var episodeId: String?
        var mediaType: String
        var title: String
        var state: String
        var relativeDirectory: String
        var createdAt: Date
        var updatedAt: Date
        @Attribute(.codable) var media: LocalMediaSnapshot
        @Relationship(deleteRule: .cascade, inverse: \DownloadPart.record) var parts: [DownloadPart]

        init(key: MediaKey) {
            id = UUID()
            self.key = key.rawValue
            serverConnectionID = key.serverConnectionID
            libraryItemId = key.libraryItemId
            mediaType = MediaType.book.rawValue
            title = "Downloading"
            state = DownloadState.paused.rawValue
            relativeDirectory = key.libraryItemId
            createdAt = Fixtures.date
            updatedAt = Fixtures.date
            media = Fixtures.bookSnapshot
            parts = []
        }
    }

    @Model final class DownloadPart {
        #Unique<DownloadPart>([\.id])
        #Index<DownloadPart>([\.taskIdentifier], [\.state])

        var id: UUID
        var record: DownloadRecord?
        var kind: String
        var serverPath: String
        var filename: String
        var mimeType: String
        var serverIno: String?
        var trackIndex: Int?
        var episodeId: String?
        var expectedBytes: Int64
        var bytesWritten: Int64
        var destinationRelativePath: String
        var state: String
        var taskIdentifier: Int?
        var hasResumeData: Bool
        var retryCount: Int
        var lastError: String?
        var lastErrorCode: String?

        init(destinationRelativePath: String) {
            id = UUID()
            kind = DownloadPartKind.audio.rawValue
            serverPath = "/api/items/li_2/file/1/download"
            filename = (destinationRelativePath as NSString).lastPathComponent
            mimeType = "audio/mpeg"
            trackIndex = 1
            expectedBytes = 100
            bytesWritten = 0
            self.destinationRelativePath = destinationRelativePath
            state = DownloadPartState.queued.rawValue
            hasResumeData = false
            retryCount = 0
        }
    }
}

/// Stores written before downloads recorded their library still open, keeping their rows with
/// no library, which Home then reads from the server (#571).
@Suite struct LibraryIDMigrationTests {
    @Test func aStoreFromBeforeLibraryIDsKeepsItsDownloadsWithoutOne() async throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Audiobookshelf.store")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let recordKey = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_2")

        do {
            // Written as the previous build wrote it, without the migration plan.
            let schema = Schema(versionedSchema: PreLibraryIDSchema.self)
            let container = try ModelContainer(
                for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
            let context = ModelContext(container)
            context.insert(Fixtures.connection(id: Fixtures.connectionID))
            let item = PreLibraryIDSchema.LocalLibraryItem(
                serverConnectionID: Fixtures.connectionID, libraryItemId: "li_1")
            context.insert(item)
            item.files = [PreLibraryIDSchema.LocalFile(relativePath: "li_1/part1.mp3")]
            let record = PreLibraryIDSchema.DownloadRecord(key: recordKey)
            context.insert(record)
            record.parts = [PreLibraryIDSchema.DownloadPart(destinationRelativePath: "li_2/part1.mp3")]
            try context.save()
        }

        let stack = try DataStack(location: .url(url))
        let items = LocalItemStore(modelContainer: stack.container)
        let item = try #require(
            try await items.item(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_1"))
        #expect(item.libraryId == nil)
        #expect(item.title == "The Book")
        #expect(item.media == Fixtures.bookSnapshot)
        #expect(item.files.map(\.relativePath) == ["li_1/part1.mp3"])
        let record = try #require(try await DownloadStore(modelContainer: stack.container).record(key: recordKey))
        #expect(record.libraryId == nil)
        #expect(record.parts.map(\.destinationRelativePath) == ["li_2/part1.mp3"])
        // Opened in place, not reset: nothing was moved aside.
        #expect(
            !FileManager.default.fileExists(atPath: directory.appending(path: "Broken").path(percentEncoded: false)))
    }
}
