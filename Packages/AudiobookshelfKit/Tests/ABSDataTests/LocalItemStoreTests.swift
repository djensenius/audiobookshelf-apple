import ABSCore
import Foundation
import SwiftData
import Testing

@testable import ABSData

@Suite struct LocalItemStoreTests {
    private let now = Fixtures.date
    private let bookKey = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_1")

    /// A store whose container already holds the fixtures' connection.
    private func makeStore() throws -> (LocalItemStore, ModelContainer) {
        let container = try DataStack(location: .inMemory).container
        let context = ModelContext(container)
        context.insert(Fixtures.connection(id: Fixtures.connectionID))
        try context.save()
        return (LocalItemStore(modelContainer: container), container)
    }

    private func part(
        _ kind: DownloadPartKind, _ filename: String, trackIndex: Int? = nil, episodeId: String? = nil,
        directory: String = "li_1"
    ) -> DownloadPartDTO {
        DownloadPartDTO(
            kind: kind,
            serverPath: "/api/items/li/file/1/download",
            filename: filename,
            mimeType: "application/octet-stream",
            serverIno: "ino-\(filename)",
            trackIndex: trackIndex,
            episodeId: episodeId,
            expectedBytes: 100,
            bytesWritten: 100,
            destinationRelativePath: "\(directory)/\(filename)",
            state: .completed
        )
    }

    private func bookDownload(parts: [DownloadPartDTO]) -> DownloadRecordDTO {
        DownloadRecordDTO(
            key: bookKey, mediaType: .book, title: "The Book", state: .downloading, relativeDirectory: "li_1",
            media: Fixtures.bookSnapshot, parts: parts)
    }

    /// An episode download, titled like the engine titles it: after the episode.
    private func episodeDownload(
        _ episode: LocalMediaSnapshot.Episode, directory: String = "li_2", partEpisodeId: String?? = .none
    ) -> DownloadRecordDTO {
        DownloadRecordDTO(
            key: MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_2", episodeId: episode.id),
            mediaType: .podcast, title: episode.title, relativeDirectory: directory,
            media: LocalMediaSnapshot(metadata: .init(title: "The Podcast"), episodes: [episode]),
            parts: [
                part(
                    .audio, "\(episode.id).mp3", episodeId: partEpisodeId ?? episode.id, directory: directory)
            ])
    }

    private var bookParts: [DownloadPartDTO] {
        [
            part(.audio, "part2.mp3", trackIndex: 2),
            part(.audio, "part1.mp3", trackIndex: 1),
            part(.ebook, "book.epub"),
            part(.cover, "cover.jpg"),
        ]
    }

    @Test func upsertFromDownloadCreatesItem() async throws {
        let (store, _) = try makeStore()
        let item = try await store.upsertFromDownload(bookDownload(parts: bookParts), coverUpdatedAt: now, now: now)

        #expect(item.serverConnectionID == Fixtures.connectionID)
        #expect(item.serverAddress == "https://abs.example.com")
        #expect(item.serverUserId == "usr_1")
        #expect(item.libraryItemId == "li_1")
        #expect(item.mediaType == .book)
        #expect(item.authorName == "Author One, Author Two")
        #expect(item.coverRelativePath == "li_1/cover.jpg")
        #expect(item.coverUpdatedAt == now)
        #expect(item.addedAt == now)
        #expect(item.media == Fixtures.bookSnapshot)
        #expect(item.files.map(\.relativePath) == ["li_1/part1.mp3", "li_1/part2.mp3", "li_1/book.epub"])
        #expect(item.files.map(\.kind) == [.audio, .audio, .ebook])
        #expect(try await store.item(id: item.id) == item)
        #expect(try await store.item(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_1") == item)
    }

    @Test func upsertFromDownloadRequiresConnection() async throws {
        let store = LocalItemStore(modelContainer: try DataStack(location: .inMemory).container)
        await #expect(throws: LocalItemStore.StoreError.connectionNotFound(Fixtures.connectionID)) {
            try await store.upsertFromDownload(bookDownload(parts: bookParts))
        }
    }

    @Test func repeatedUpsertKeepsIDsAndReplacesBookFiles() async throws {
        let (store, container) = try makeStore()
        let first = try await store.upsertFromDownload(bookDownload(parts: bookParts), coverUpdatedAt: now, now: now)
        let later = now.addingTimeInterval(60)
        let second = try await store.upsertFromDownload(
            bookDownload(parts: [part(.audio, "part1.mp3", trackIndex: 1)]), now: later)

        #expect(second.id == first.id)
        #expect(second.addedAt == now)
        #expect(second.updatedAt == later)
        // No cover part and no cover time: the stored cover is kept.
        #expect(second.coverRelativePath == "li_1/cover.jpg")
        #expect(second.coverUpdatedAt == now)
        #expect(second.files.map(\.id) == [first.files[0].id])
        #expect(try await store.allItems().count == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocalFile>()) == 1)
    }

    @Test func upsertFallsBackToTheSnapshotCoverTime() async throws {
        let (store, _) = try makeStore()
        var download = bookDownload(parts: bookParts)
        download.media.coverUpdatedAt = now
        let item = try await store.upsertFromDownload(download, now: now)

        #expect(item.coverUpdatedAt == now)
    }

    @Test func explicitCoverTimeWinsOverTheSnapshot() async throws {
        let (store, _) = try makeStore()
        var download = bookDownload(parts: bookParts)
        download.media.coverUpdatedAt = now
        let explicit = now.addingTimeInterval(60)
        let item = try await store.upsertFromDownload(download, coverUpdatedAt: explicit, now: now)

        #expect(item.coverUpdatedAt == explicit)
    }

    @Test func noCoverTimeKeepsTheStoredOne() async throws {
        let (store, _) = try makeStore()
        var download = bookDownload(parts: bookParts)
        download.media.coverUpdatedAt = now
        try await store.upsertFromDownload(download, now: now)
        download.media.coverUpdatedAt = nil
        let item = try await store.upsertFromDownload(download, now: now)

        #expect(item.coverUpdatedAt == now)
    }

    @Test func episodeWithoutCoverTimeKeepsTheItemsCoverTime() async throws {
        let (store, _) = try makeStore()
        let episode1 = Fixtures.podcastSnapshot.episodes[0]
        var episode2 = episode1
        episode2.id = "ep_2"
        var first = episodeDownload(episode1)
        first.media.coverUpdatedAt = now
        try await store.upsertFromDownload(first, now: now)
        let second = try await store.upsertFromDownload(episodeDownload(episode2), now: now)

        #expect(second.coverUpdatedAt == now)
        #expect(second.media.coverUpdatedAt == now)
    }

    @Test func concurrentUpsertsOfTheSameItemCreateOneRow() async throws {
        let (store, container) = try makeStore()
        let download = bookDownload(parts: bookParts)
        let ids = try await withThrowingTaskGroup(of: UUID.self) { group in
            for _ in 0..<8 {
                group.addTask { try await store.upsertFromDownload(download).id }
            }
            return try await group.reduce(into: Set<UUID>()) { $0.insert($1) }
        }
        #expect(ids.count == 1)
        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<LocalLibraryItem>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<LocalFile>()) == 3)
    }

    @Test func podcastEpisodesMergeIntoOneItem() async throws {
        let (store, _) = try makeStore()
        let episode1 = Fixtures.podcastSnapshot.episodes[0]
        var episode2 = episode1
        episode2.id = "ep_2"
        episode2.title = "Episode 2"

        let first = try await store.upsertFromDownload(episodeDownload(episode1), now: now)
        let second = try await store.upsertFromDownload(episodeDownload(episode2), now: now)
        #expect(second.id == first.id)
        #expect(second.media.episodes.map(\.id) == ["ep_1", "ep_2"])
        #expect(Set(second.files.map(\.episodeId)) == ["ep_1", "ep_2"])

        // Downloading an episode again keeps the other episode and the file's id.
        let again = try await store.upsertFromDownload(episodeDownload(episode1), now: now)
        #expect(again.files.count == 2)
        #expect(again.files.first { $0.episodeId == "ep_1" }?.id == first.files[0].id)
        #expect(Set(again.media.episodes.map(\.id)) == ["ep_1", "ep_2"])

        let deleted = try #require(try await store.deleteEpisode(itemID: first.id, episodeId: "ep_1"))
        #expect(deleted.removedFiles.map(\.relativePath) == ["li_2/ep_1.mp3"])
        #expect(deleted.itemIsEmpty == false)
        let remaining = try #require(try await store.item(id: first.id))
        #expect(remaining.files.map(\.episodeId) == ["ep_2"])
        #expect(remaining.media.episodes.map(\.id) == ["ep_2"])

        // A missing episode removes nothing; the last one leaves the item empty.
        let missing = try await store.deleteEpisode(itemID: first.id, episodeId: "ep_9")
        #expect(missing == LocalItemStore.EpisodeDeletion(removedFiles: [], itemIsEmpty: false))
        let last = try #require(try await store.deleteEpisode(itemID: first.id, episodeId: "ep_2"))
        #expect(last.removedFiles.map(\.episodeId) == ["ep_2"])
        #expect(last.itemIsEmpty)
        #expect(try await store.item(id: first.id)?.files.isEmpty == true)
        #expect(try await store.deleteEpisode(itemID: UUID(), episodeId: "ep_2") == nil)
    }

    @Test func podcastItemKeepsPodcastTitleAndDirectory() async throws {
        let (store, _) = try makeStore()
        let episode1 = Fixtures.podcastSnapshot.episodes[0]
        var episode2 = episode1
        episode2.id = "ep_2"
        episode2.title = "Episode 2"

        let first = try await store.upsertFromDownload(episodeDownload(episode1), now: now)
        #expect(first.title == "The Podcast")
        #expect(first.relativeDirectory == "li_2")
        // A later episode download with another directory doesn't move the item, and a part
        // without an episode id still files under the download's episode.
        let second = try await store.upsertFromDownload(
            episodeDownload(episode2, directory: "elsewhere", partEpisodeId: .some(nil)), now: now)
        #expect(second.title == "The Podcast")
        #expect(second.relativeDirectory == "li_2")
        #expect(second.files.first { $0.relativePath == "elsewhere/ep_2.mp3" }?.episodeId == "ep_2")
    }

    @Test func upsertFromDownloadRequiresEveryPartCompleted() async throws {
        let (store, _) = try makeStore()
        var parts = bookParts
        parts[1].state = .running
        await #expect(throws: LocalItemStore.StoreError.incompleteDownload) {
            try await store.upsertFromDownload(bookDownload(parts: parts))
        }
        await #expect(throws: LocalItemStore.StoreError.incompleteDownload) {
            try await store.upsertFromDownload(bookDownload(parts: []))
        }
        #expect(try await store.allItems().isEmpty)
    }

    @Test func failedSaveIsRolledBackAndNotCommittedLater() async throws {
        let (store, container) = try makeStore()
        let item = try await store.upsertFromDownload(bookDownload(parts: bookParts), now: now)

        await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        await #expect(throws: CocoaError.self) { try await store.deleteItem(id: item.id) }
        #expect(await store.hasUncommittedChanges == false)
        // A failed multi-object write leaves nothing behind either.
        var other = bookDownload(parts: bookParts)
        other.key = MediaKey(serverConnectionID: Fixtures.connectionID, libraryItemId: "li_5")
        await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        await #expect(throws: CocoaError.self) { try await store.upsertFromDownload(other) }
        #expect(await store.hasUncommittedChanges == false)

        // A later, unrelated save doesn't commit the failed changes.
        #expect(try await store.updateCover(itemID: item.id, relativePath: nil, updatedAt: nil))
        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<LocalLibraryItem>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<LocalFile>()) == 3)
        #expect(try await store.item(id: item.id)?.coverRelativePath == nil)
    }

    @Test func listsAndUpdatesCover() async throws {
        let (store, container) = try makeStore()
        let other = Fixtures.connection(id: UUID(), userId: "usr_2")
        let context = ModelContext(container)
        context.insert(other)
        try context.save()

        let book = try await store.upsertFromDownload(bookDownload(parts: bookParts), now: now)
        var otherDownload = bookDownload(parts: bookParts)
        otherDownload.key = MediaKey(serverConnectionID: other.id, libraryItemId: "li_1")
        let otherBook = try await store.upsertFromDownload(otherDownload, now: now.addingTimeInterval(1))

        #expect(try await store.allItems().map(\.id) == [otherBook.id, book.id])
        #expect(try await store.items(serverConnectionID: other.id).map(\.id) == [otherBook.id])
        #expect(otherBook.serverUserId == "usr_2")

        let coverTime = now.addingTimeInterval(100)
        #expect(try await store.updateCover(itemID: book.id, relativePath: "li_1/cover.png", updatedAt: coverTime))
        let updated = try #require(try await store.item(id: book.id))
        #expect(updated.coverRelativePath == "li_1/cover.png")
        #expect(updated.coverUpdatedAt == coverTime)
        #expect(try await store.updateCover(itemID: UUID(), relativePath: nil, updatedAt: nil) == false)
    }

    @Test func deleteItemCascadesToFilesOnly() async throws {
        let (store, container) = try makeStore()
        let item = try await store.upsertFromDownload(bookDownload(parts: bookParts), now: now)
        let context = ModelContext(container)
        let progress = Fixtures.progress()
        progress.localLibraryItemID = item.id
        context.insert(progress)
        try context.save()

        #expect(try await store.deleteItem(id: item.id) == item)
        #expect(try await store.item(id: item.id) == nil)
        #expect(try await store.deleteItem(id: item.id) == nil)
        #expect(try context.fetchCount(FetchDescriptor<LocalFile>()) == 0)
        // Progress is owned by `LocalProgressStore`; deleting the item doesn't touch it.
        #expect(try context.fetchCount(FetchDescriptor<LocalMediaProgress>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<ServerConnectionRecord>()) == 1)
    }
}
