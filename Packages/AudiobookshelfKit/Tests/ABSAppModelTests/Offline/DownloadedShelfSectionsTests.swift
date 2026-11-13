import ABSCore
import ABSData
import ABSDownloads
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ABSAppModel

@MainActor
@Suite(.timeLimit(.minutes(1))) struct DownloadedShelfSectionsTests {
    private let connectionID = UUID()
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(
        _ title: String, _ mediaType: MediaType = .book, author: String? = nil,
        metadata: LocalMediaSnapshot.Metadata? = nil, tracks: [Double] = [], files: [LocalFileKind] = [.audio],
        coverUpdatedAt: Date? = nil, addedAt offset: TimeInterval = 0
    ) -> LocalLibraryItemDTO {
        LocalLibraryItemDTO(
            id: UUID(), serverConnectionID: connectionID, serverAddress: "https://abs.example.com",
            serverUserId: "usr_1", libraryItemId: "li_\(title)", mediaType: mediaType, title: title,
            authorName: author, relativeDirectory: title, coverUpdatedAt: coverUpdatedAt,
            addedAt: date.addingTimeInterval(offset), updatedAt: date,
            media: LocalMediaSnapshot(
                metadata: metadata ?? .init(title: title),
                audioTracks: tracks.enumerated().map { index, duration in
                    .init(index: index, title: "\(index)", duration: duration, startOffset: 0, mimeType: "audio/mpeg")
                }),
            files: files.map {
                LocalFileDTO(kind: $0, relativePath: "\(title)/f", filename: "f", mimeType: "audio/mpeg", size: 1)
            })
    }

    private func ids(_ sections: [HomeSection]) -> [String] { sections.map(\.id) }

    @Test func aDownloadedBookIsTheServersItemWithItsDownloadedCover() throws {
        let updated = Date(timeIntervalSince1970: 1_700_000_000.5)
        let book = item(
            "Book", author: "Ann Author", metadata: .init(title: "Book", explicit: true, abridged: true),
            tracks: [60, 30.5], coverUpdatedAt: updated)

        let summary = ItemSummary(localItem: book)
        #expect(summary.id == "li_Book" && summary.itemID == "li_Book")
        #expect(summary.kind == .book && summary.title == "Book" && summary.subtitle == "Ann Author")
        #expect(summary.duration == 90.5)
        #expect(summary.isExplicit && summary.isAbridged && summary.hasAudio && !summary.isMissing)
        #expect(summary.cover == CoverRef(entityID: "li_Book", updatedAt: 1_700_000_000_500))
        #expect(summary.episodeID == nil)
    }

    @Test func aBookWithoutAuthorNameOrAudioFallsBack() {
        let ebook = item("Ebook", metadata: .init(title: "Ebook", authors: ["A", "B"]), files: [.ebook])

        let summary = ItemSummary(localItem: ebook)
        #expect(summary.subtitle == "A, B")
        #expect(summary.duration == nil)
        #expect(!summary.hasAudio)
        #expect(summary.cover == CoverRef(entityID: "li_Ebook"))
        #expect(ItemSummary(localItem: item("Unknown", author: "")).subtitle == nil)
    }

    @Test func aDownloadedPodcastIsTheWholePodcast() {
        let podcast = item("Show", .podcast, author: "Host", tracks: [120])

        let summary = ItemSummary(localItem: podcast)
        #expect(summary.kind == .podcast && summary.itemID == "li_Show" && summary.subtitle == "Host")
        #expect(summary.duration == nil && !summary.hasAudio && summary.episodeID == nil)
    }

    @Test func booksComeBeforePodcastsAndEmptyShelvesAreLeftOut() throws {
        let books = [item("New", addedAt: 5), item("Old")]
        let podcasts = [item("Show", .podcast)]

        let both = DownloadedShelfModel.sections(books: books, podcasts: podcasts, for: nil)
        #expect(ids(both) == ["local-books", "local-podcasts"])
        let first = try #require(both.first)
        #expect(first.titleKey == "LabelLocalBooks" && first.label == "Local Books" && first.kind == .book)
        #expect(first.entries.map(\.id) == ["li_New", "li_Old"])
        let last = try #require(both.last)
        #expect(last.titleKey == "LabelLocalPodcasts" && last.kind == .podcast)

        #expect(ids(DownloadedShelfModel.sections(books: [], podcasts: podcasts, for: nil)) == ["local-podcasts"])
        #expect(ids(DownloadedShelfModel.sections(books: books, podcasts: [], for: nil)) == ["local-books"])
        #expect(DownloadedShelfModel.sections(books: [], podcasts: [], for: nil).isEmpty)
    }

    @Test func aLibraryKindKeepsOnlyItsShelf() {
        let books = [item("Book")]
        let podcasts = [item("Show", .podcast)]

        #expect(ids(DownloadedShelfModel.sections(books: books, podcasts: podcasts, for: .book)) == ["local-books"])
        #expect(
            ids(DownloadedShelfModel.sections(books: books, podcasts: podcasts, for: .podcast)) == ["local-podcasts"])
        #expect(DownloadedShelfModel.sections(books: [], podcasts: podcasts, for: .book).isEmpty)
    }

    @Test func theModelsSectionsFollowItsShelves() async {
        let (stream, continuation) = AsyncStream.makeStream(of: [LocalLibraryItemDTO].self)
        let model = DownloadedShelfModel { _ in stream }
        let task = Task { await model.observe(connectionID: connectionID) }
        defer { task.cancel() }
        #expect(model.sections(for: nil).isEmpty)

        continuation.yield([item("Old"), item("Show", .podcast, addedAt: 1), item("New", addedAt: 2)])
        while !model.isLoaded, !Task.isCancelled { await Task.yield() }
        #expect(ids(model.sections(for: nil)) == ["local-books", "local-podcasts"])
        #expect(model.sections(for: .book).first?.entries.map(\.id) == ["li_New", "li_Old"])
        #expect(ids(model.sections(for: .podcast)) == ["local-podcasts"])
    }

    /// A downloaded card's cover key finds the item's cover file through the pipeline's downloaded
    /// lookup with nothing cached and no network (ADR 0005, "Offline covers"). Its version
    /// matches the file's, so the file is fresh for the key and online it isn't fetched again.
    @Test func aDownloadedCardsCoverLoadsFromItsFileOffline() async throws {
        let root = URL.temporaryDirectory.appending(path: "DownloadedShelfCovers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = DownloadLocations(root: root)
        let container = try DataStack(location: .inMemory).container
        let connection = try await ServerConnectionStore(modelContainer: container).upsertLogin(
            address: try #require(ServerAddress("https://abs.example.com")), userId: "usr_1", username: "user",
            authMethod: .local, serverVersion: nil)
        let store = LocalItemStore(modelContainer: container)
        let parts = [("cover.jpg", DownloadPartKind.cover), ("a.mp3", .audio)].map { filename, kind in
            DownloadPartDTO(
                kind: kind, serverPath: "/api/items/li_1/file", filename: filename,
                mimeType: "application/octet-stream", destinationRelativePath: "li_1/\(filename)", state: .completed)
        }
        _ = try await store.upsertFromDownload(
            DownloadRecordDTO(
                key: MediaKey(serverConnectionID: connection.id, libraryItemId: "li_1"), mediaType: .book,
                title: "The Book", relativeDirectory: "li_1",
                media: LocalMediaSnapshot(metadata: .init(title: "The Book")), parts: parts),
            coverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000.123))
        try writeJPEG(to: try locations.fileURL(forRelativePath: "li_1/cover.jpg"))
        let item = try #require(try await store.item(serverConnectionID: connection.id, libraryItemId: "li_1"))
        let key = try #require(ItemSummary(localItem: item).cover).key(serverID: connection.id, bucket: .small)
        let pipeline = ImagePipeline(
            limits: .iPhone, fileStore: CoverFileStore(directory: root.appending(path: "Images"), limit: 1 << 20),
            downloadedCovers: LocalDownloadedCovers(store: store, locations: locations), isOnline: { false })

        let image = try await pipeline.cgImage(for: key, size: CGSize(width: 32, height: 48))
        #expect(image.width > 0 && image.height > 0)
        // Only a downloaded cover at least as new as the key is stored for it.
        let stored = try await pipeline.ensureCoverFile(for: key)
        #expect(FileManager.default.fileExists(atPath: stored.path(percentEncoded: false)))
    }

    private func writeJPEG(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: 64, height: 96, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 96))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
