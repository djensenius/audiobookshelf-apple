import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSAppModel

@Suite
struct LocalItemDetailTests {
    static let connection = UUID()
    static let address = "https://abs.example"
    static let account = LocalItemDetail.Account(connectionID: connection, address: address, userID: "user")

    static func item(
        mediaType: MediaType = .book, connection: UUID = connection, address: String = address,
        userID: String = "user", media: LocalMediaSnapshot = LocalMediaSnapshot(metadata: .init(title: "Walden")),
        files: [LocalFileDTO] = [], id: UUID = UUID()
    ) -> LocalLibraryItemDTO {
        LocalLibraryItemDTO(
            id: id, serverConnectionID: connection, serverAddress: address, serverUserId: userID, libraryItemId: "li1",
            mediaType: mediaType, title: "Walden", authorName: "Thoreau", relativeDirectory: "walden",
            addedAt: .now, updatedAt: .now, media: media, files: files)
    }

    static func file(
        _ name: String, kind: LocalFileKind = .audio, size: Int64, trackIndex: Int? = nil, episodeId: String? = nil
    ) -> LocalFileDTO {
        LocalFileDTO(
            kind: kind, relativePath: name, filename: name,
            mimeType: kind == .ebook ? "application/epub+zip" : "audio/mpeg",
            size: size, trackIndex: trackIndex, episodeId: episodeId)
    }

    @Test func listsBookTracksByNumberWithSnapshotTitlesAndDurations() {
        let media = LocalMediaSnapshot(
            metadata: .init(title: "Walden"),
            audioTracks: [
                .init(index: 1, title: "Economy", duration: 600, startOffset: 0, mimeType: "audio/mpeg"),
                .init(index: 2, title: "Where I Lived", duration: 300, startOffset: 600, mimeType: "audio/mpeg"),
            ],
            ebookFile: .init(ino: "9", filename: "walden.epub", format: "epub"))
        let item = Self.item(
            media: media,
            files: [
                Self.file("02.mp3", size: 20, trackIndex: 2), Self.file("loose.mp3", size: 5),
                Self.file("01.mp3", size: 10, trackIndex: 1), Self.file("walden.epub", kind: .ebook, size: 7),
            ])

        let detail = LocalItemDetail(item: item, account: Self.account)

        #expect(detail.tracks.map(\.title) == ["Economy", "Where I Lived", "loose.mp3"])
        #expect(detail.tracks.map(\.index) == [1, 2, nil])
        #expect(detail.tracks.map(\.duration) == [600, 300, nil])
        #expect(detail.ebooks.map(\.filename) == ["walden.epub"])
        #expect(detail.ebooks.first?.format == "epub")
        #expect(detail.episodes.isEmpty)
        #expect(detail.otherFiles.isEmpty)
        #expect(detail.audioBytes == 35)
        #expect(detail.ebookBytes == 7)
        #expect(detail.totalBytes == 42)
        #expect(detail.totalDuration == 900)
    }

    @Test func listsPodcastEpisodesNewestFirstWithTheirSizes() {
        let media = LocalMediaSnapshot(
            metadata: .init(title: "Radio"),
            episodes: [
                .init(id: "e1", title: "Old", publishedAt: Date(timeIntervalSince1970: 1_000), duration: 60),
                .init(id: "e2", title: "New", publishedAt: Date(timeIntervalSince1970: 2_000), duration: 120),
            ])
        let item = Self.item(
            mediaType: .podcast, media: media,
            files: [
                Self.file("old.mp3", size: 10, episodeId: "e1"), Self.file("new.mp3", size: 20, episodeId: "e2"),
                Self.file("stray.mp3", size: 4, episodeId: "e9"), Self.file("orphan.mp3", size: 3),
            ])

        let detail = LocalItemDetail(item: item, account: Self.account)

        #expect(detail.episodes.map(\.title) == ["New", "Old", "stray.mp3"])
        #expect(detail.episodes.map(\.byteCount) == [20, 10, 4])
        #expect(detail.episodes.map(\.duration) == [120, 60, nil])
        #expect(detail.tracks.isEmpty)
        #expect(detail.otherFiles.map(\.filename) == ["orphan.mp3"])
        #expect(detail.audioBytes == 34)
        #expect(detail.totalBytes == 37)
    }

    @Test func blankTrackAndEpisodeTitlesFallBackToTheFilename() {
        let book = Self.item(
            media: LocalMediaSnapshot(
                metadata: .init(title: "Walden"),
                audioTracks: [
                    .init(index: 1, title: "", duration: 60, startOffset: 0, mimeType: "audio/mpeg"),
                    .init(index: 2, title: " \n\t", duration: 60, startOffset: 60, mimeType: "audio/mpeg"),
                ]),
            files: [Self.file("01.mp3", size: 1, trackIndex: 1), Self.file("02.mp3", size: 1, trackIndex: 2)])
        #expect(LocalItemDetail(item: book, account: nil).tracks.map(\.title) == ["01.mp3", "02.mp3"])

        let podcast = Self.item(
            mediaType: .podcast,
            media: LocalMediaSnapshot(
                metadata: .init(title: "Radio"),
                episodes: [
                    .init(id: "e1", title: "  ", publishedAt: Date(timeIntervalSince1970: 2_000), duration: 60),
                    .init(id: "e2", title: "", publishedAt: Date(timeIntervalSince1970: 1_000), duration: 60),
                ]),
            files: [Self.file("one.mp3", size: 1, episodeId: "e1")])
        #expect(LocalItemDetail(item: podcast, account: nil).episodes.map(\.title) == ["one.mp3", "e2"])
    }

    @Test func clampsNegativeSizes() {
        let detail = LocalItemDetail(item: Self.item(files: [Self.file("a.mp3", size: -5)]), account: nil)
        #expect(detail.totalBytes == 0)
    }

    /// Sizes come from the server, so sums that overflow `Int64` saturate instead of trapping,
    /// as in ``DownloadsListing``: per episode, per kind and in total.
    @Test func byteTotalsSaturateInsteadOfOverflowing() {
        let huge = Int64.max - 10
        let book = LocalItemDetail(
            item: Self.item(files: [
                Self.file("01.mp3", size: huge, trackIndex: 1), Self.file("02.mp3", size: huge, trackIndex: 2),
                Self.file("a.epub", kind: .ebook, size: huge), Self.file("b.epub", kind: .ebook, size: huge),
            ]), account: nil)
        #expect(book.audioBytes == .max)
        #expect(book.ebookBytes == .max)
        #expect(book.totalBytes == .max)

        let podcast = LocalItemDetail(
            item: Self.item(
                mediaType: .podcast,
                media: LocalMediaSnapshot(metadata: .init(title: "Radio"), episodes: [.init(id: "e1", title: "Pilot")]),
                files: [
                    Self.file("e1a.mp3", size: huge, episodeId: "e1"),
                    Self.file("e1b.mp3", size: huge, episodeId: "e1"),
                    Self.file("x.mp3", size: huge), Self.file("y.mp3", size: huge),
                ]), account: nil)
        #expect(podcast.episodes.first?.byteCount == .max)
        #expect(podcast.totalBytes == .max)
    }

    struct LinkCase: Sendable, CustomTestStringConvertible {
        let name: String
        let connection: UUID
        let address: String
        let userID: String
        let signedIn: Bool
        let expected: LocalItemDetail.LinkStatus
        var testDescription: String { name }
    }

    static let linkCases: [LinkCase] = [
        LinkCase(
            name: "this account", connection: connection, address: address, userID: "user", signedIn: true,
            expected: .thisAccount),
        LinkCase(
            name: "same server, other address spelling", connection: UUID(), address: "HTTPS://abs.example/",
            userID: "user", signedIn: true, expected: .otherConnection),
        LinkCase(
            name: "other server", connection: UUID(), address: "https://other.example", userID: "user",
            signedIn: true, expected: .otherServer("https://other.example")),
        LinkCase(
            name: "other user", connection: UUID(), address: address, userID: "someone", signedIn: true,
            expected: .otherUser),
        LinkCase(
            name: "signed out", connection: connection, address: address, userID: "user", signedIn: false,
            expected: .linked(address)),
    ]

    @Test(arguments: linkCases)
    func mapsTheLinkToTheSignedInAccount(_ link: LinkCase) {
        let item = Self.item(connection: link.connection, address: link.address, userID: link.userID)
        let detail = LocalItemDetail(item: item, account: link.signedIn ? Self.account : nil)
        #expect(detail.link == link.expected)
    }
}
