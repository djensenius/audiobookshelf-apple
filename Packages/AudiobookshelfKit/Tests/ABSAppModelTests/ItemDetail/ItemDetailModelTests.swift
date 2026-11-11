import ABSAPI
import ABSCore
import Foundation
import Observation
import Testing

@testable import ABSAppModel

/// An ``ItemDetailService`` whose responses come from a closure.
private struct FakeItemDetailService: ItemDetailService {
    var handler: @Sendable (String) async throws -> LibraryItem

    func item(id: String) async throws -> LibraryItem { try await handler(id) }
}

private func makeBook(
    id: String = "li-1", title: String = "The Book", duration: Double? = 1000, trackCount: Int = 2,
    ebookFile: EbookFile? = nil, ebookFormat: EbookFormat? = nil, isMissing: Bool = false, isInvalid: Bool = false
) -> LibraryItem {
    let tracks = (0..<trackCount).map { index in
        AudioTrack(index: index + 1, duration: (duration ?? 0) / Double(max(trackCount, 1)))
    }
    let metadata = BookMetadata(
        title: title, subtitle: "A Subtitle",
        authors: [Author(id: "au-1", name: "Ann"), Author(id: "au-x", name: " "), Author(id: "au-2", name: "Bo")],
        narrators: ["Nora", ""],
        series: [
            Series(id: "se-1", name: "Saga", sequence: "2"), Series(id: "se-blank", name: " "),
            Series(id: "se-unnamed", name: "", sequence: "3"), Series(id: "se-2", name: "Arc"),
        ],
        genres: ["Fantasy"], publishedYear: "2020", publisher: "Pub House", description: "<p>Hi</p>", language: " ",
        explicit: true, abridged: false)
    let book = Book(
        id: "book-\(id)", libraryItemId: id, metadata: metadata, tags: ["Tag"],
        ebookFile: ebookFile, tracks: tracks, duration: duration, size: 50, ebookFormat: ebookFormat)
    return LibraryItem(
        id: id, libraryId: "lib", isMissing: isMissing, isInvalid: isInvalid, mediaType: .book, media: .book(book),
        size: 123)
}

private func progress(
    _ itemID: String = "li-1", duration: Double = 1000, progress: Double = 0,
    currentTime: Double = 0, isFinished: Bool = false, ebookProgress: Double? = nil, finishedAt: Int? = nil,
    lastUpdate: Int = 1
) -> MediaProgress {
    MediaProgress(
        id: "p-\(itemID)", libraryItemId: itemID, duration: duration,
        progress: progress, currentTime: currentTime, isFinished: isFinished, ebookProgress: ebookProgress,
        lastUpdate: lastUpdate, finishedAt: finishedAt)
}

@MainActor
private func loadedModel(
    _ item: LibraryItem = makeBook(), cache: ProgressCache = ProgressCache()
) async -> ItemDetailModel {
    let model = ItemDetailModel(itemID: item.id, service: FakeItemDetailService { _ in item }, cache: cache)
    await model.load()
    return model
}

@MainActor
@Suite struct ItemDetailModelTests {
    @Test func loadsTheItemAndItsDetails() async throws {
        let requested = Locked<[String]>([])
        let model = ItemDetailModel(
            itemID: "li-1",
            service: FakeItemDetailService { id in
                requested.value.append(id)
                return makeBook(id: id)
            }, cache: ProgressCache())
        #expect(!model.hasLoaded)
        #expect(model.mediaType == nil)
        #expect(model.playButton == .unavailable)

        await model.loadIfNeeded()
        await model.loadIfNeeded()

        #expect(requested.value == ["li-1"])
        #expect(model.hasLoaded)
        #expect(!model.isLoading)
        #expect(model.error == nil)
        #expect(model.mediaType == .book)
        #expect(model.summary?.itemID == "li-1")
        let details = try #require(model.details)
        #expect(details.title == "The Book")
        #expect(details.subtitle == "A Subtitle")
        #expect(details.authors.map(\.name) == ["Ann", "Bo"])
        #expect(details.narrators == ["Nora"])
        #expect(details.series.map(\.text) == ["Saga #2", "Arc"])
        #expect(details.series.map(\.id) == ["se-1", "se-2"])
        #expect(details.genres == ["Fantasy"])
        #expect(details.tags == ["Tag"])
        #expect(details.publisher == "Pub House")
        #expect(details.year == "2020")
        #expect(details.language == nil)
        #expect(details.description == "<p>Hi</p>")
        #expect(details.duration == 1000)
        #expect(details.size == 123)
        #expect(details.isExplicit)
        #expect(!details.isAbridged)
    }

    @Test func blankMetadataBecomesNil() {
        let metadata = BookMetadata(
            title: "T", subtitle: " ", authors: [Author(id: "au", name: "\n")], narrators: ["\t"],
            series: [Series(id: "se", name: "  ")], genres: [" "], publishedYear: "", publisher: " ",
            description: " \n", language: "")
        let book = Book(id: "b", metadata: metadata, tags: [" "])
        let item = LibraryItem(id: "li", libraryId: "lib", mediaType: .book, media: .book(book))
        let details = ItemDetailModel.details(item: item, book: book)
        #expect(details.title == "T")
        #expect(details.subtitle == nil)
        #expect(details.publisher == nil)
        #expect(details.year == nil)
        #expect(details.language == nil)
        #expect(details.description == nil)
        #expect(details.authors.isEmpty)
        #expect(details.narrators.isEmpty)
        #expect(details.series.isEmpty)
        #expect(details.genres.isEmpty)
        #expect(details.tags.isEmpty)
    }

    @Test func aFailedFirstLoadReportsTheError() async {
        let model = ItemDetailModel(
            itemID: "li-1", service: FakeItemDetailService { _ in throw TestError.offline }, cache: ProgressCache())
        await model.load()

        #expect(model.error is TestError)
        #expect(!model.hasLoaded)
        #expect(!model.refreshFailed)
        #expect(!model.isLoading)
        #expect(model.playButton == .unavailable)
    }

    @Test func aFailedReloadKeepsTheItem() async {
        let fails = Locked(false)
        let model = ItemDetailModel(
            itemID: "li-1",
            service: FakeItemDetailService { id in
                if fails.value { throw TestError.offline }
                return makeBook(id: id)
            }, cache: ProgressCache())
        await model.load()

        fails.value = true
        await model.load()
        #expect(model.item?.id == "li-1")
        #expect(model.details?.title == "The Book")
        #expect(model.error is TestError)
        #expect(model.refreshFailed)
        #expect(model.playButton == .play)

        fails.value = false
        await model.load()
        #expect(model.error == nil)
        #expect(!model.refreshFailed)
    }

    @Test func aCancelledReloadKeepsTheItemWithoutAnError() async {
        let cancels = Locked(false)
        let model = ItemDetailModel(
            itemID: "li-1",
            service: FakeItemDetailService { id in
                if cancels.value { throw CancellationError() }
                return makeBook(id: id)
            }, cache: ProgressCache())
        await model.load()

        cancels.value = true
        await model.load()
        #expect(model.error == nil)
        #expect(model.item?.id == "li-1")
        #expect(!model.isLoading)
        #expect(!model.refreshFailed)
    }

    @Test func aRetryIsLoadingAndNotRefreshFailed() async throws {
        let gate = GatedCalls<String, LibraryItem>()
        var calls = gate.calls.makeAsyncIterator()
        let model = ItemDetailModel(
            itemID: "li-1", service: FakeItemDetailService { id in try await gate.call(id) }, cache: ProgressCache())

        let first = Task { await model.load() }
        let firstCall = try #require(await calls.next())
        #expect(model.isLoading)
        #expect(!model.hasLoaded)
        firstCall.reply.resume(returning: makeBook())
        await first.value

        let failing = Task { await model.load() }
        try #require(await calls.next()).reply.resume(throwing: TestError.offline)
        await failing.value
        #expect(model.refreshFailed)

        // While the retry runs, the old error is still set but the page shows loading.
        let retry = Task { await model.load() }
        let retryCall = try #require(await calls.next())
        #expect(model.isLoading)
        #expect(model.error is TestError)
        #expect(!model.refreshFailed)
        #expect(model.item?.id == "li-1")

        retryCall.reply.resume(returning: makeBook())
        await retry.value
        #expect(!model.isLoading)
        #expect(model.error == nil)
    }

    @Test func aLateResponseToAnOlderLoadIsDropped() async throws {
        let gate = GatedCalls<String, LibraryItem>()
        var calls = gate.calls.makeAsyncIterator()
        let model = ItemDetailModel(
            itemID: "li-1", service: FakeItemDetailService { id in try await gate.call(id) }, cache: ProgressCache())

        let first = Task { await model.load() }
        let firstCall = try #require(await calls.next())
        let second = Task { await model.load() }
        let secondCall = try #require(await calls.next())

        secondCall.reply.resume(returning: makeBook(title: "New"))
        await second.value
        #expect(model.details?.title == "New")
        #expect(!model.isLoading)

        firstCall.reply.resume(returning: makeBook(title: "Old"))
        await first.value
        #expect(model.details?.title == "New")
        #expect(!model.isLoading)

        // A late failure of an older load doesn't report an error either.
        let third = Task { await model.load() }
        let thirdCall = try #require(await calls.next())
        let fourth = Task { await model.load() }
        let fourthCall = try #require(await calls.next())
        fourthCall.reply.resume(returning: makeBook(title: "Newest"))
        await fourth.value
        thirdCall.reply.resume(throwing: TestError.offline)
        await third.value
        #expect(model.details?.title == "Newest")
        #expect(model.error == nil)
    }

    @Test func playButtonFollowsProgress() async {
        let cache = ProgressCache()
        let model = await loadedModel(cache: cache)
        #expect(model.playButton == .play)
        #expect(model.playStartTime == nil)

        cache.apply(progress(progress: 0, lastUpdate: 1))
        #expect(model.playButton == .play)

        // A position without progress isn't started, for the button and the time left alike.
        cache.apply(progress(progress: 0, currentTime: 30, lastUpdate: 2))
        #expect(model.playButton == .play)
        #expect(model.timeRemaining == nil)

        cache.apply(progress(progress: 0.4, currentTime: 400, lastUpdate: 2))
        #expect(model.playButton == .resume)
        #expect(model.playStartTime == nil)

        cache.apply(progress(progress: 1, currentTime: 1000, isFinished: true, lastUpdate: 3))
        #expect(model.playButton == .playAgain)
        #expect(model.playStartTime == 0)

        // Ebook-only progress doesn't resume audio.
        cache.apply(progress(progress: 0, ebookProgress: 0.5, lastUpdate: 4))
        #expect(model.playButton == .play)
        #expect(model.progressFraction == 0.5)
    }

    @Test func playIsUnavailableWithoutAudio() async {
        let cache = ProgressCache()
        cache.apply(progress(progress: 0.4, currentTime: 400))
        #expect(await loadedModel(makeBook(trackCount: 0), cache: cache).playButton == .unavailable)
        #expect(await loadedModel(makeBook(trackCount: 0), cache: cache).playStartTime == nil)
        #expect(await loadedModel(makeBook(isMissing: true), cache: cache).playButton == .unavailable)
        #expect(await loadedModel(makeBook(isMissing: true), cache: cache).isMissing)
        #expect(await loadedModel(makeBook(isInvalid: true), cache: cache).playButton == .unavailable)

        // Tracks make a book playable even when the server reports no duration (legacy showPlay).
        let zeroDuration = await loadedModel(makeBook(duration: 0), cache: cache)
        #expect(zeroDuration.hasAudio)
        #expect(zeroDuration.playButton == .resume)
        #expect(zeroDuration.details?.duration == nil)

        let podcast = LibraryItem(
            id: "li-1", libraryId: "lib", mediaType: .podcast,
            media: .podcast(Podcast(id: "pod", metadata: PodcastMetadata(title: "Show"))))
        let podcastModel = await loadedModel(podcast, cache: cache)
        #expect(podcastModel.mediaType == .podcast)
        #expect(podcastModel.details == nil)
        #expect(podcastModel.playButton == .unavailable)
    }

    @Test func timeRemaining() async {
        let cache = ProgressCache()
        let model = await loadedModel(cache: cache)
        #expect(model.timeRemaining == nil)
        #expect(model.progressFraction == 0)

        cache.apply(progress(duration: 1000, progress: 0.4, currentTime: 400, lastUpdate: 1))
        #expect(model.timeRemaining == 600)
        #expect(model.progressFraction == 0.4)

        // Without a duration on the progress, the media's is used.
        cache.apply(progress(duration: 0, progress: 0.25, currentTime: 250, lastUpdate: 2))
        #expect(model.timeRemaining == 750)

        cache.apply(progress(duration: 1000, progress: 0.99, currentTime: 1200, lastUpdate: 3))
        #expect(model.timeRemaining == 0)

        cache.apply(progress(progress: 0, ebookProgress: 0.3, lastUpdate: 4))
        #expect(model.timeRemaining == nil)

        cache.apply(
            progress(progress: 1, currentTime: 1000, isFinished: true, finishedAt: 1_700_000_000_000, lastUpdate: 5))
        #expect(model.timeRemaining == nil)
        #expect(model.isFinished)
        #expect(model.progressFraction == 1)
        #expect(model.finishedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func aFinishedItemShowsFullProgress() async {
        // Deliberately unlike legacy, which showed the raw progress: finished reads as 100%, as on cells.
        let cache = ProgressCache()
        cache.apply(progress(progress: 0.97, currentTime: 970, isFinished: true))
        let model = await loadedModel(cache: cache)
        #expect(model.progressFraction == 1)
        #expect(model.playButton == .playAgain)
    }

    @Test func readNeedsAnEbookAndStaysDisabled() async {
        let withEbook = await loadedModel(makeBook(ebookFile: EbookFile(ino: "eb-1", ebookFormat: .epub)))
        #expect(withEbook.hasEbook)
        #expect(withEbook.ebookFormat == .epub)
        #expect(!withEbook.isReadEnabled)

        // An ebook file without a format is still an ebook.
        let unknownFormat = await loadedModel(makeBook(ebookFile: EbookFile(ino: "eb-1")))
        #expect(unknownFormat.hasEbook)
        #expect(unknownFormat.ebookFormat == nil)
        #expect(!unknownFormat.isReadEnabled)

        // A minified book only carries the format.
        let minified = await loadedModel(makeBook(ebookFormat: .pdf))
        #expect(minified.hasEbook)
        #expect(minified.ebookFormat == .pdf)

        let both = await loadedModel(
            makeBook(ebookFile: EbookFile(ino: "eb-1", ebookFormat: .epub), ebookFormat: .pdf))
        #expect(both.ebookFormat == .epub)

        let without = await loadedModel(makeBook())
        #expect(!without.hasEbook)
        #expect(without.ebookFormat == nil)
        #expect(!without.isDownloadAvailable)
    }

    @Test func observationFollowsTheItemsCacheEntry() async {
        let cache = ProgressCache()
        let model = await loadedModel(cache: cache)
        let changed = Locked(false)
        withObservationTracking {
            _ = model.playButton
            _ = model.timeRemaining
        } onChange: {
            changed.value = true
        }

        cache.apply(progress("other", progress: 0.5, currentTime: 500))
        #expect(!changed.value)

        cache.apply(progress(progress: 0.5, currentTime: 500))
        #expect(changed.value)
        #expect(model.playButton == .resume)
    }
}
