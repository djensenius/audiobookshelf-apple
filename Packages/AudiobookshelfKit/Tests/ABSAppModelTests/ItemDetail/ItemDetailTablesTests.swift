import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

/// An ``ItemDetailService`` whose responses come from a closure.
private struct FakeItemDetailService: ItemDetailService {
    var handler: @Sendable (String) async throws -> LibraryItem

    func item(id: String) async throws -> LibraryItem { try await handler(id) }
}

private func file(_ name: String, ext: String?, size: Int? = nil) -> FileMetadata {
    FileMetadata(filename: name, ext: ext, path: "/books/\(name)", size: size)
}

private func makeBook(
    id: String = "li-1", duration: Double? = 1000, chapters: [Chapter]? = nil, tracks: [AudioTrack]? = nil,
    ebookFile: EbookFile? = nil, libraryFiles: [LibraryFile]? = nil, isMissing: Bool = false
) -> LibraryItem {
    let book = Book(
        id: "book-\(id)", libraryItemId: id, metadata: BookMetadata(title: "The Book"), chapters: chapters,
        ebookFile: ebookFile, tracks: tracks ?? [AudioTrack(index: 1, duration: duration ?? 0)], duration: duration)
    return LibraryItem(
        id: id, libraryId: "lib", isMissing: isMissing, mediaType: .book, media: .book(book),
        libraryFiles: libraryFiles)
}

@MainActor
private func loadedModel(_ item: LibraryItem) async -> ItemDetailModel {
    let model = ItemDetailModel(itemID: item.id, service: FakeItemDetailService { _ in item }, cache: ProgressCache())
    await model.load()
    return model
}

@MainActor
@Suite struct ItemDetailTablesTests {
    @Test func chaptersSortedWithClampedDurations() async {
        let model = await loadedModel(
            makeBook(chapters: [
                Chapter(id: 2, start: 300, end: 600, title: "Two"),
                Chapter(id: 0, start: 0, end: 120, title: "Zero"),
                Chapter(id: 1, start: 120, end: 100, title: "Ends before it starts"),
                Chapter(id: 3, start: -5, end: 10, title: "Negative"),
                Chapter(id: 4, start: .nan, end: 50, title: "NaN"),
            ]))

        // Equal starts keep the server's order.
        #expect(model.chapters.map(\.chapterID) == [0, 3, 4, 1, 2])
        #expect(model.chapters.map(\.id) == [0, 1, 2, 3, 4])
        #expect(model.chapters.map(\.start) == [0, 0, 0, 120, 300])
        #expect(model.chapters.map(\.duration) == [120, 10, 50, 0, 300])
        #expect(model.chapters.first { $0.chapterID == 2 }?.title == "Two")
    }

    @Test func duplicateChapterAndTrackIDsStayDistinctRows() async {
        let model = await loadedModel(
            makeBook(
                chapters: [
                    Chapter(id: 1, start: 0, end: 10, title: "Same"), Chapter(id: 1, start: 0, end: 10, title: "Same"),
                ],
                tracks: [AudioTrack(duration: 5, title: "a.mp3"), AudioTrack(duration: 5, title: "a.mp3")]))

        #expect(model.chapters.map(\.chapterID) == [1, 1])
        #expect(model.chapters.map(\.id) == [0, 1])
        #expect(model.chapters[0] != model.chapters[1])
        #expect(model.tracks.map(\.trackID) == ["0-0.0", "0-0.0"])
        #expect(model.tracks.map(\.id) == [0, 1])
        #expect(model.tracks[0] != model.tracks[1])
    }

    @Test func chaptersEmptyForPodcastAndMissingChapters() async {
        #expect(await loadedModel(makeBook(chapters: nil)).chapters.isEmpty)
        #expect(await loadedModel(makeBook(chapters: [])).chapters.isEmpty)

        let podcast = LibraryItem(
            id: "li-1", libraryId: "lib", mediaType: .podcast,
            media: .podcast(Podcast(id: "pod", metadata: PodcastMetadata(title: "Show"))),
            libraryFiles: [LibraryFile(ino: "eb", metadata: file("a.epub", ext: ".epub"), fileType: "ebook")])
        let model = await loadedModel(podcast)
        #expect(model.chapters.isEmpty)
        #expect(model.tracks.isEmpty)
        #expect(model.ebookFiles.isEmpty)
        #expect(!model.canPlayChapters)
    }

    @Test func tracksPreferFilenameThenTitleThenNil() async {
        let model = await loadedModel(
            makeBook(tracks: [
                AudioTrack(index: 1, duration: 10, title: "Title 1", metadata: file("01.mp3", ext: ".mp3")),
                AudioTrack(index: 2, duration: 20, title: "Title 2", metadata: file(" ", ext: nil)),
                AudioTrack(index: 3, duration: 30, title: "Title 3"),
                AudioTrack(index: 4, duration: -1, title: ""),
            ]))

        #expect(model.tracks.map(\.name) == ["01.mp3", "Title 2", "Title 3", nil])
        #expect(model.tracks.map(\.duration) == [10, 20, 30, 0])
        #expect(model.tracks.map(\.trackID) == ["1-0.0", "2-0.0", "3-0.0", "4-0.0"])
    }

    @Test func tracksSortedByIndexKeepingNilIndexOrder() async {
        let model = await loadedModel(
            makeBook(tracks: [
                AudioTrack(index: nil, startOffset: 50, duration: 1, title: "B"),
                AudioTrack(index: 3, startOffset: 20, duration: 1, title: "Three"),
                AudioTrack(index: nil, startOffset: 40, duration: 1, title: "A"),
                AudioTrack(index: 1, startOffset: 0, duration: 1, title: "One"),
                AudioTrack(index: 2, startOffset: 10, duration: 1, title: "Two"),
            ]))

        #expect(model.tracks.map(\.name) == ["One", "Two", "Three", "B", "A"])
        #expect(model.tracks.map(\.index) == [1, 2, 3, nil, nil])
    }

    @Test func ebookFilesOnlyEbookFileType() async {
        let model = await loadedModel(
            makeBook(libraryFiles: [
                LibraryFile(ino: "au", metadata: file("01.mp3", ext: ".mp3"), fileType: "audio"),
                LibraryFile(ino: "eb-1", metadata: file("book.epub", ext: ".epub", size: 2_048), fileType: "ebook"),
                LibraryFile(ino: "im", metadata: file("cover.jpg", ext: ".jpg"), fileType: "image"),
                LibraryFile(ino: "md", metadata: file("metadata.json", ext: ".json"), fileType: "metadata"),
                LibraryFile(ino: "eb-2", metadata: file("book.pdf", ext: ".pdf"), fileType: "ebook"),
                LibraryFile(ino: "none", metadata: file("notes.txt", ext: ".txt")),
                LibraryFile(ino: "eb-3", fileType: "ebook"),
            ]))

        #expect(model.ebookFiles.map(\.id) == ["eb-1", "eb-2", "eb-3"])
        #expect(model.ebookFiles.map(\.filename) == ["book.epub", "book.pdf", ""])
        #expect(model.ebookFiles.map(\.size) == [2_048, nil, nil])
        #expect(await loadedModel(makeBook()).ebookFiles.isEmpty)
    }

    @Test func ebookPrimaryFlagAndFormatFromExtension() async {
        let model = await loadedModel(
            makeBook(
                ebookFile: EbookFile(ino: "eb-2", ebookFormat: .pdf),
                libraryFiles: [
                    LibraryFile(ino: "eb-1", metadata: file("A.EPUB", ext: ".EPUB"), fileType: "ebook"),
                    LibraryFile(ino: "eb-2", metadata: file("b.Pdf", ext: "Pdf"), fileType: "ebook"),
                    LibraryFile(ino: "eb-3", metadata: file("c.djvu", ext: ".djvu"), fileType: "ebook"),
                    LibraryFile(ino: "eb-4", metadata: file("d", ext: ""), fileType: "ebook"),
                    LibraryFile(ino: "eb-5", metadata: file("e", ext: nil), fileType: "ebook"),
                ]))

        #expect(model.ebookFiles.map(\.isPrimary) == [false, true, false, false, false])
        #expect(model.ebookFiles.map(\.format) == [.epub, .pdf, .unknown("djvu"), nil, nil])

        let withoutPrimary = await loadedModel(
            makeBook(libraryFiles: [
                LibraryFile(ino: "eb-1", metadata: file("a.epub", ext: ".epub"), fileType: "ebook")
            ]))
        #expect(withoutPrimary.ebookFiles.map(\.isPrimary) == [false])
    }

    @Test func startTimeClampsNegativeAndNonFinite() async {
        let model = await loadedModel(makeBook(duration: 1000))
        func start(_ seconds: Double) -> TimeInterval {
            model.startTime(for: .init(id: 0, chapterID: 0, title: "", start: seconds, duration: 10))
        }

        #expect(start(-5) == 0)
        #expect(start(.nan) == 0)
        #expect(start(.infinity) == 0)
        #expect(start(-.infinity) == 0)
        #expect(start(0) == 0)
        #expect(start(120.5) == 120.5)
        // Within the book: before its end.
        #expect(start(1000) < 1000)
        #expect(start(1000) > 999)
        #expect(start(5000) < 1000)

        // Without a known duration only the lower bound applies.
        let noDuration = await loadedModel(makeBook(duration: nil))
        #expect(noDuration.startTime(for: .init(id: 0, chapterID: 0, title: "", start: 5000, duration: 0)) == 5000)
        #expect(noDuration.startTime(for: .init(id: 0, chapterID: 0, title: "", start: -1, duration: 0)) == 0)
    }

    @Test func canPlayChaptersFalseWhenMissingOrNoTracks() async {
        let chapters = [Chapter(id: 0, start: 0, end: 10, title: "One")]
        #expect(await loadedModel(makeBook(chapters: chapters)).canPlayChapters)
        #expect(!(await loadedModel(makeBook(chapters: chapters, tracks: [])).canPlayChapters))
        #expect(!(await loadedModel(makeBook(chapters: chapters, isMissing: true)).canPlayChapters))

        let unloaded = ItemDetailModel(
            itemID: "li-1", service: FakeItemDetailService { _ in throw TestError.offline }, cache: ProgressCache())
        #expect(!unloaded.canPlayChapters)
        await unloaded.load()
        #expect(!unloaded.canPlayChapters)
    }

    @Test func chapterToPlayWhenStillTheSameChapter() async throws {
        let model = await loadedModel(
            makeBook(chapters: [
                Chapter(id: 0, start: 0, end: 100, title: "One"), Chapter(id: 1, start: 100, end: 200, title: "Two"),
            ]))
        let second = try #require(model.chapters.last)
        #expect(model.chapterToPlay(confirming: second) == 100)
    }

    @Test func chapterToPlayIsNilWhenTheChapterChanged() async throws {
        let version = Locked(0)
        let model = ItemDetailModel(
            itemID: "li-1",
            service: FakeItemDetailService { _ in
                switch version.value {
                case 0:
                    makeBook(chapters: [
                        Chapter(id: 0, start: 0, end: 100, title: "One"),
                        Chapter(id: 1, start: 100, end: 200, title: "Two"),
                    ])
                case 1:
                    makeBook(chapters: [
                        Chapter(id: 0, start: 0, end: 100, title: "One"),
                        Chapter(id: 1, start: 150, end: 200, title: "Two"),
                    ])
                default:
                    makeBook(chapters: [Chapter(id: 0, start: 0, end: 100, title: "One")])
                }
            }, cache: ProgressCache())
        await model.load()
        let second = try #require(model.chapters.last)
        let first = try #require(model.chapters.first)

        // Same position and ID, new start.
        version.value = 1
        await model.load()
        #expect(model.chapterToPlay(confirming: second) == nil)
        #expect(model.chapterToPlay(confirming: first) == 0)

        // Removed.
        version.value = 2
        await model.load()
        #expect(model.chapterToPlay(confirming: second) == nil)
    }

    @Test func chapterToPlayIsNilWhenGoneOrWithoutAudio() async throws {
        let chapters = [Chapter(id: 0, start: 0, end: 100, title: "One")]
        let failure = Locked<(any Error & Sendable)?>(nil)
        let tracks = Locked<[AudioTrack]?>(nil)
        let model = ItemDetailModel(
            itemID: "li-1",
            service: FakeItemDetailService { _ in
                if let error = failure.value { throw error }
                return makeBook(chapters: chapters, tracks: tracks.value)
            }, cache: ProgressCache())
        await model.load()
        let chapter = try #require(model.chapters.first)
        #expect(model.chapterToPlay(confirming: chapter) == 0)

        // A reload that fails some other way keeps it playable.
        failure.value = TestError.offline
        await model.load()
        #expect(model.chapterToPlay(confirming: chapter) == 0)

        failure.value = APIError.notFound
        await model.load()
        #expect(model.chapters == [chapter])
        #expect(model.chapterToPlay(confirming: chapter) == nil)

        failure.value = nil
        await model.load()
        #expect(model.chapterToPlay(confirming: chapter) == 0)

        tracks.value = []
        await model.load()
        #expect(model.chapters == [chapter])
        #expect(model.chapterToPlay(confirming: chapter) == nil)

        let missing = await loadedModel(makeBook(chapters: chapters, isMissing: true))
        #expect(missing.chapterToPlay(confirming: chapter) == nil)
    }

    @Test func reloadReplacesRows() async {
        let second = Locked(false)
        let model = ItemDetailModel(
            itemID: "li-1",
            service: FakeItemDetailService { _ in
                second.value
                    ? makeBook(
                        chapters: [Chapter(id: 9, start: 0, end: 5, title: "New")],
                        tracks: [AudioTrack(index: 1, duration: 5, title: "new.mp3")], libraryFiles: [])
                    : makeBook(
                        chapters: [Chapter(id: 1, start: 0, end: 5, title: "Old")],
                        tracks: [AudioTrack(index: 1, duration: 5, title: "old.mp3")],
                        libraryFiles: [
                            LibraryFile(ino: "eb", metadata: file("a.epub", ext: ".epub"), fileType: "ebook")
                        ])
            }, cache: ProgressCache())
        #expect(model.chapters.isEmpty)
        #expect(model.tracks.isEmpty)
        #expect(model.ebookFiles.isEmpty)

        await model.load()
        #expect(model.chapters.map(\.title) == ["Old"])
        #expect(model.tracks.map(\.name) == ["old.mp3"])
        #expect(model.ebookFiles.map(\.id) == ["eb"])

        second.value = true
        await model.load()
        #expect(model.chapters.map(\.title) == ["New"])
        #expect(model.tracks.map(\.name) == ["new.mp3"])
        #expect(model.ebookFiles.isEmpty)
    }

    @Test func failedReloadKeepsRows() async {
        let fails = Locked(false)
        let model = ItemDetailModel(
            itemID: "li-1",
            service: FakeItemDetailService { _ in
                if fails.value { throw TestError.offline }
                return makeBook(
                    chapters: [Chapter(id: 1, start: 0, end: 5, title: "Kept")],
                    libraryFiles: [LibraryFile(ino: "eb", metadata: file("a.epub", ext: ".epub"), fileType: "ebook")])
            }, cache: ProgressCache())
        await model.load()

        fails.value = true
        await model.load()
        #expect(model.refreshFailed)
        #expect(model.chapters.map(\.title) == ["Kept"])
        #expect(model.tracks.count == 1)
        #expect(model.ebookFiles.map(\.id) == ["eb"])
    }
}
