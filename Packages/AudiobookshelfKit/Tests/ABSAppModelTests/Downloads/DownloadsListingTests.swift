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

    /// A record as `DownloadPlanner` builds it: titled by the book or the episode, with the
    /// snapshot's metadata titled by the book or the `podcast`.
    static func record(
        _ title: String, state: DownloadState, connection: UUID = connection, episodeId: String? = nil,
        podcast: String? = nil, episodes: [LocalMediaSnapshot.Episode] = [],
        parts: [(expected: Int64, written: Int64)] = []
    ) -> DownloadRecordDTO {
        DownloadRecordDTO(
            key: MediaKey(serverConnectionID: connection, libraryItemId: "li-\(title)", episodeId: episodeId),
            mediaType: episodeId == nil ? .book : .podcast, title: title, state: state, relativeDirectory: title,
            media: LocalMediaSnapshot(metadata: .init(title: podcast ?? title), episodes: episodes),
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

    /// The planner titles an episode's record by the episode and keeps the podcast's title in
    /// the snapshot's metadata. The negative control: the record's own title is the episode's.
    @Test func titlesEpisodeDownloadsByEpisodeUnderThePodcast() throws {
        let record = Self.record(
            "Pilot", state: .queued, episodeId: "e1", podcast: "Radio", episodes: [.init(id: "e1", title: "Pilot")])
        let listing = DownloadsListing(items: [], records: [record], progress: [:], serverConnectionID: Self.connection)

        let download = try #require(listing.downloads.first)
        #expect(download.title == "Pilot")
        #expect(download.subtitle == "Radio")
        #expect(record.title == "Pilot")

        let book = Self.record("Walden", state: .queued)
        #expect(
            DownloadsListing(items: [], records: [book], progress: [:], serverConnectionID: Self.connection)
                .downloads.first?.subtitle == nil)
    }

    /// Live progress is `bytes` over the sizes the transfers have learned, which can differ from
    /// the stored ones: the row, its byte label and the ring all use the live size. The negative
    /// control is the stored size, which they used before.
    @Test func liveExpectedSizesDriveTheRowLabelAndRing() throws {
        let grown = Self.record("Grown", state: .downloading, parts: [(100, 0)])
        let unsized = Self.record("Unsized", state: .downloading, parts: [(0, 0)])
        let unknown = Self.record("Unknown", state: .downloading, parts: [(100, 0)])
        let listing = DownloadsListing(
            items: [], records: [grown, unsized, unknown],
            progress: [
                grown.id: .init(fraction: 0.5, bytes: 100), unsized.id: .init(fraction: 0.25, bytes: 50),
                // No size known live yet: the stored one stands.
                unknown.id: .init(fraction: 0, bytes: 30),
            ],
            serverConnectionID: Self.connection)

        #expect(listing.downloads.map(\.expectedBytes) == [200, 200, 100])
        #expect(listing.downloads.map(\.bytesWritten) == [100, 50, 30])
        #expect(listing.downloads.map(\.status) == [.downloading(0.5), .downloading(0.25), .downloading(0.3)])
        #expect(listing.downloadingFraction == 180.0 / 500.0)
        #expect(
            DownloadsListing.status(of: grown, progress: .init(fraction: 0.5, bytes: 100)) == .downloading(0.5))

        #expect(grown.parts.map(\.expectedBytes) == [100])
        #expect(unsized.parts.map(\.expectedBytes) == [0])
    }

    /// A retry or restart without resume data starts over below the saved bytes: with live
    /// progress, the row, its byte label and the ring show the live bytes, not the larger saved
    /// ones. The negative control: without live progress, the saved bytes stand.
    @Test func liveBytesBelowTheSavedOnesWin() throws {
        let restarted = Self.record("Restarted", state: .downloading, parts: [(100, 80)])
        let listing = DownloadsListing(
            items: [], records: [restarted], progress: [restarted.id: .init(fraction: 0.1, bytes: 10)],
            serverConnectionID: Self.connection)

        let download = try #require(listing.downloads.first)
        #expect(download.status == .downloading(0.1))
        #expect(download.bytesWritten == 10)
        #expect(download.expectedBytes == 100)
        #expect(listing.downloadingFraction == 0.1)
        #expect(
            DownloadsListing.status(of: restarted, progress: .init(fraction: 0.1, bytes: 10)) == .downloading(0.1))

        let saved = DownloadsListing(
            items: [], records: [restarted], progress: [:], serverConnectionID: Self.connection)
        #expect(saved.downloads.first?.status == .downloading(0.8))
        #expect(saved.downloads.first?.bytesWritten == 80)
        #expect(saved.downloadingFraction == 0.8)
    }

    /// Sizes come from the server, so sums that overflow `Int64` saturate, and fractions are
    /// summed as `Double`, instead of trapping. The negative control: the same sums overflow.
    @Test func byteTotalsSaturateInsteadOfOverflowing() throws {
        let huge = Int64.max - 10
        let book = Self.item("Walden", files: [Self.file(size: huge), Self.file(size: huge)])
        let podcast = Self.item(
            "Radio", mediaType: .podcast, episodes: [.init(id: "e1", title: "Pilot")],
            files: [Self.file(size: huge, episodeId: "e1"), Self.file(size: huge, episodeId: "e1")])
        let stored = Self.record("Stored", state: .downloading, parts: [(huge, huge), (huge, 10)])
        let live = Self.record("Live", state: .paused, parts: [(huge, 0)])
        let listing = DownloadsListing(
            items: [book, podcast], records: [stored, live],
            progress: [live.id: .init(fraction: 0.5, bytes: .max)], serverConnectionID: Self.connection)

        #expect(listing.books.first?.byteCount == .max)
        #expect(listing.podcasts.first?.byteCount == .max)
        #expect(listing.podcasts.first?.episodes.first?.byteCount == .max)
        #expect(listing.downloadedBytes == .max)
        #expect(listing.downloads.map(\.expectedBytes) == [.max, .max])
        #expect(listing.downloads.map(\.bytesWritten) == [.max, .max])
        #expect(listing.downloads.map(\.status) == [.downloading(0.5), .paused(0.5)])
        #expect(listing.downloadingFraction == 0.5)

        #expect(huge.addingReportingOverflow(huge).overflow)
    }

    /// A cover's `updatedAt` is `LocalDownloadedCovers`'s checked conversion, rounded to the
    /// millisecond, so the row's key matches the downloaded cover's; a stored timestamp past
    /// `Int`'s range (the planner stores the server's milliseconds as a date) is unknown instead
    /// of trapping. The negative controls: those timestamps don't fit in `Int`.
    @Test func coverVersionIsCheckedAndRounded() throws {
        func version(_ date: Date?) throws -> Int? {
            var item = Self.item("Walden")
            item.coverUpdatedAt = date
            let listing = DownloadsListing(
                items: [item], records: [], progress: [:], serverConnectionID: Self.connection)
            return try #require(listing.books.first).coverVersion
        }
        let milliseconds = 1_700_000_000_123.6
        #expect(try version(Date(timeIntervalSince1970: milliseconds / 1000)) == 1_700_000_000_124)
        #expect(try version(nil) == nil)
        let farFuture = Date(timeIntervalSince1970: Double(Int.max) / 1000)
        #expect(try version(farFuture) == nil)
        let farPast = Date(timeIntervalSince1970: -Double(Int.max) / 500)
        #expect(try version(farPast) == nil)

        #expect(farFuture.timeIntervalSince1970 * 1000 >= Double(Int.max))
        #expect(farPast.timeIntervalSince1970 * 1000 < Double(Int.min))
    }

    @Test func onlyPausedAndFailedDownloadsAreRetryable() {
        #expect(DownloadsListing.Status.failed.isRetryable)
        #expect(DownloadsListing.Status.paused(0.5).isRetryable)
        #expect(!DownloadsListing.Status.queued.isRetryable)
        #expect(!DownloadsListing.Status.downloading(0.5).isRetryable)
    }
}
