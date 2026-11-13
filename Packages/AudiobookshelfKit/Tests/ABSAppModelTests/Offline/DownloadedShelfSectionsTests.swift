import ABSCore
import ABSData
import Foundation
import Testing

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
}
