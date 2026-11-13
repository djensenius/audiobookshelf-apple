import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSAppModel

@Suite
struct DownloadsListingTests {
    static let connection = UUID()
    static let otherConnection = UUID()

    static func item(
        _ title: String, mediaType: MediaType = .book, connection: UUID = connection, id: UUID = UUID(),
        episodes: [LocalMediaSnapshot.Episode] = [], files: [LocalFileDTO] = []
    ) -> LocalLibraryItemDTO {
        LocalLibraryItemDTO(
            id: id, serverConnectionID: connection, serverAddress: "https://abs.example", serverUserId: "user",
            libraryItemId: "li-\(title)", mediaType: mediaType, title: title, relativeDirectory: title,
            addedAt: .now, updatedAt: .now,
            media: LocalMediaSnapshot(metadata: .init(title: title), episodes: episodes), files: files)
    }

    static func file(_ kind: LocalFileKind = .audio, size: Int64, episodeId: String? = nil, name: String = "f.mp3")
        -> LocalFileDTO
    {
        LocalFileDTO(
            kind: kind, relativePath: name, filename: name, mimeType: "audio/mpeg", size: size, episodeId: episodeId)
    }

    static func record(
        _ title: String, state: DownloadState, connection: UUID = connection, episodeId: String? = nil,
        episodes: [LocalMediaSnapshot.Episode] = [], parts: [(expected: Int64, written: Int64)] = []
    ) -> DownloadRecordDTO {
        DownloadRecordDTO(
            key: MediaKey(serverConnectionID: connection, libraryItemId: "li-\(title)", episodeId: episodeId),
            mediaType: episodeId == nil ? .book : .podcast, title: title, state: state, relativeDirectory: title,
            media: LocalMediaSnapshot(metadata: .init(title: title), episodes: episodes),
            parts: parts.map {
                DownloadPartDTO(
                    kind: .audio, serverPath: "/f", filename: "f.mp3", mimeType: "audio/mpeg",
                    expectedBytes: $0.expected,
                    bytesWritten: $0.written, destinationRelativePath: "f.mp3")
            })
    }

    @Test func groupsBooksAndPodcastsOfTheConnectionByTitle() {
        let listing = DownloadsListing(
            items: [
                Self.item("Walden"), Self.item("Book 10"), Self.item("Book 9"),
                Self.item("Radio", mediaType: .podcast), Self.item("Elsewhere", connection: Self.otherConnection),
            ],
            records: [
                Self.record("Queued", state: .queued),
                Self.record("Other", state: .queued, connection: Self.otherConnection),
            ],
            progress: [:], serverConnectionID: Self.connection)

        #expect(listing.books.map(\.title) == ["Book 9", "Book 10", "Walden"])
        #expect(listing.podcasts.map(\.title) == ["Radio"])
        #expect(listing.downloads.map(\.title) == ["Queued"])
    }

    @Test func listsNothingWithoutAConnection() {
        let listing = DownloadsListing(
            items: [Self.item("Walden")], records: [Self.record("Queued", state: .queued)], progress: [:],
            serverConnectionID: nil)

        #expect(listing.isEmpty)
    }

    @Test func sumsFileSizesAndCountsTracks() throws {
        let book = Self.item(
            "Walden",
            files: [Self.file(size: 100), Self.file(size: 50), Self.file(.ebook, size: 25), Self.file(size: -10)])
        let listing = DownloadsListing(items: [book], records: [], progress: [:], serverConnectionID: Self.connection)

        let row = try #require(listing.books.first)
        #expect(row.byteCount == 175)
        #expect(row.trackCount == 3)
        #expect(row.hasEbook)
        #expect(listing.downloadedBytes == 175)
    }

    @Test func ordersEpisodesNewestFirstAndKeepsFileOnlyEpisodes() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let podcast = Self.item(
            "Radio", mediaType: .podcast,
            episodes: [
                .init(id: "e1", title: "Old", publishedAt: old), .init(id: "e2", title: "New", publishedAt: new),
                .init(id: "e3", title: "Undated"),
            ],
            files: [
                Self.file(size: 10, episodeId: "e1"), Self.file(size: 20, episodeId: "e2"),
                Self.file(size: 5, episodeId: "e4", name: "stray.mp3"),
            ])
        let listing = DownloadsListing(
            items: [podcast], records: [], progress: [:], serverConnectionID: Self.connection)

        let episodes = listing.podcasts.first?.episodes ?? []
        #expect(episodes.map(\.title) == ["New", "Old", "stray.mp3", "Undated"])
        #expect(episodes.map(\.byteCount) == [20, 10, 5, 0])
        #expect(listing.downloadedBytes == 35)
    }

    @Test func mapsRecordStatesToRowStates() {
        let parts: [(expected: Int64, written: Int64)] = [(100, 25), (100, 25)]
        #expect(DownloadsListing.status(of: Self.record("a", state: .queued), progress: nil) == .queued)
        #expect(DownloadsListing.status(of: Self.record("a", state: .failed), progress: nil) == .failed)
        #expect(
            DownloadsListing.status(of: Self.record("a", state: .downloading, parts: parts), progress: nil)
                == .downloading(0.25))
        #expect(
            DownloadsListing.status(of: Self.record("a", state: .paused, parts: parts), progress: nil) == .paused(0.25))
        #expect(DownloadsListing.status(of: Self.record("a", state: .downloading), progress: nil) == .downloading(0))
    }

    @Test func prefersLiveProgressClamped() {
        let record = Self.record("a", state: .downloading, parts: [(100, 10)])
        #expect(
            DownloadsListing.status(of: record, progress: .init(fraction: 0.6, bytes: 60)) == .downloading(0.6))
        #expect(DownloadsListing.status(of: record, progress: .init(fraction: 1.4, bytes: 60)) == .downloading(1))

        let listing = DownloadsListing(
            items: [], records: [record], progress: [record.id: .init(fraction: 0.6, bytes: 60)],
            serverConnectionID: Self.connection)
        #expect(listing.downloads.first?.bytesWritten == 60)
        #expect(listing.downloads.first?.expectedBytes == 100)
        #expect(listing.downloadingFraction == 0.6)
    }

    @Test func titlesEpisodeDownloadsByEpisodeUnderThePodcast() {
        let record = Self.record(
            "Radio", state: .queued, episodeId: "e1", episodes: [.init(id: "e1", title: "Pilot")])
        let listing = DownloadsListing(items: [], records: [record], progress: [:], serverConnectionID: Self.connection)

        #expect(listing.downloads.first?.title == "Pilot")
        #expect(listing.downloads.first?.subtitle == "Radio")
    }

    @Test func onlyPausedAndFailedDownloadsAreRetryable() {
        #expect(DownloadsListing.Status.failed.isRetryable)
        #expect(DownloadsListing.Status.paused(0.5).isRetryable)
        #expect(!DownloadsListing.Status.queued.isRetryable)
        #expect(!DownloadsListing.Status.downloading(0.5).isRetryable)
    }
}
