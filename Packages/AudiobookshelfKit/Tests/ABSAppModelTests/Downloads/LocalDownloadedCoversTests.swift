import ABSCore
import ABSData
import ABSDownloads
import Foundation
import SwiftData
import Testing

@testable import ABSAppModel

@Suite struct LocalDownloadedCoversTests {
    private let root = URL.temporaryDirectory.appending(path: "LocalDownloadedCovers-\(UUID().uuidString)")
    private var locations: DownloadLocations { DownloadLocations(root: root) }
    private let updatedAt = Date(timeIntervalSince1970: 1_700_000_000.123_4)

    private func writeCover(_ path: String = "li_1/cover.jpg") throws {
        let url = try locations.fileURL(forRelativePath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("jpeg".utf8).write(to: url)
    }

    private func key(_ serverID: UUID, kind: ImageKind = .itemCover, id: String = "li_1") -> ImageKey {
        ImageKey(serverID: serverID, kind: kind, entityID: id, updatedAt: 1, bucket: .small)
    }

    /// A store holding one downloaded book, `li_1`, with its cover at `li_1/cover.jpg`.
    private func makeStore() async throws -> (LocalItemStore, UUID) {
        let container = try DataStack(location: .inMemory).container
        let connection = try await ServerConnectionStore(modelContainer: container).upsertLogin(
            address: try #require(ServerAddress("https://abs.example.com")), userId: "usr_1", username: "user",
            authMethod: .local, serverVersion: nil)
        let store = LocalItemStore(modelContainer: container)
        let parts = [("cover.jpg", DownloadPartKind.cover), ("part1.mp3", .audio)].map { filename, kind in
            DownloadPartDTO(
                kind: kind, serverPath: "/api/items/li_1/file", filename: filename,
                mimeType: "application/octet-stream", destinationRelativePath: "li_1/\(filename)",
                state: .completed)
        }
        _ = try await store.upsertFromDownload(
            DownloadRecordDTO(
                key: MediaKey(serverConnectionID: connection.id, libraryItemId: "li_1"), mediaType: .book,
                title: "The Book", relativeDirectory: "li_1",
                media: LocalMediaSnapshot(metadata: .init(title: "The Book")),
                parts: parts),
            coverUpdatedAt: updatedAt)
        return (store, connection.id)
    }

    @Test func downloadedItemsCoverIsFoundWithItsVersionInMilliseconds() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, serverID) = try await makeStore()
        try writeCover()
        let covers = LocalDownloadedCovers(store: store, locations: locations)

        let cover = try #require(await covers.downloadedCover(for: key(serverID)))
        #expect(cover.fileURL == (try locations.fileURL(forRelativePath: "li_1/cover.jpg")))
        #expect(cover.updatedAt == 1_700_000_000_123)
    }

    @Test func otherServersItemsAndAuthorsAreNotFound() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, serverID) = try await makeStore()
        try writeCover()
        let covers = LocalDownloadedCovers(store: store, locations: locations)

        #expect(await covers.downloadedCover(for: key(UUID())) == nil)
        #expect(await covers.downloadedCover(for: key(serverID, id: "li_2")) == nil)
        #expect(await covers.downloadedCover(for: key(serverID, kind: .authorImage)) == nil)
    }

    @Test func missingCoverFileIsNotFound() async throws {
        let (store, serverID) = try await makeStore()
        let covers = LocalDownloadedCovers(store: store, locations: locations)
        #expect(await covers.downloadedCover(for: key(serverID)) == nil)
    }

    @Test func itemWithoutACoverOrWithAnUnsafePathIsNotFound() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, serverID) = try await makeStore()
        try writeCover()
        let item = try #require(try await store.item(serverConnectionID: serverID, libraryItemId: "li_1"))
        let covers = LocalDownloadedCovers(store: store, locations: locations)

        try await store.updateCover(itemID: item.id, relativePath: "../Downloads/li_1/cover.jpg", updatedAt: nil)
        #expect(await covers.downloadedCover(for: key(serverID)) == nil)
        try await store.updateCover(itemID: item.id, relativePath: nil, updatedAt: nil)
        #expect(await covers.downloadedCover(for: key(serverID)) == nil)
    }

    @Test func coverWithoutAVersionIsFoundWithNone() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, serverID) = try await makeStore()
        try writeCover()
        let item = try #require(try await store.item(serverConnectionID: serverID, libraryItemId: "li_1"))
        try await store.updateCover(itemID: item.id, relativePath: "li_1/cover.jpg", updatedAt: nil)
        let covers = LocalDownloadedCovers(store: store, locations: locations)

        let cover = try #require(await covers.downloadedCover(for: key(serverID)))
        #expect(cover.updatedAt == nil)

        // Too far out for an `Int` of milliseconds: no version, rather than a trap.
        try await store.updateCover(
            itemID: item.id, relativePath: "li_1/cover.jpg", updatedAt: Date(timeIntervalSince1970: 1e300))
        #expect(try #require(await covers.downloadedCover(for: key(serverID))).updatedAt == nil)
    }
}
