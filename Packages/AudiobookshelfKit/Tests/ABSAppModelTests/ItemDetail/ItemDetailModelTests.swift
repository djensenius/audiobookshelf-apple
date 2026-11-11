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
    ebook: EbookFormat? = nil, isMissing: Bool = false
) -> LibraryItem {
    let tracks = (0..<trackCount).map { index in
        AudioTrack(index: index + 1, duration: (duration ?? 0) / Double(max(trackCount, 1)))
    }
    let metadata = BookMetadata(
        title: title, subtitle: "A Subtitle",
        authors: [Author(id: "au-1", name: "Ann"), Author(id: "au-2", name: "Bo")],
        narrators: ["Nora", ""],
        series: [Series(id: "se-1", name: "Saga", sequence: "2"), Series(id: "se-2", name: "Arc")],
        genres: ["Fantasy"], publishedYear: "2020", publisher: "Pub House", description: "<p>Hi</p>", language: " ",
        explicit: true, abridged: false)
    let book = Book(
        id: "book-\(id)", libraryItemId: id, metadata: metadata, tags: ["Tag"],
        ebookFile: ebook.map { EbookFile(ino: "eb-1", ebookFormat: $0) }, tracks: tracks, duration: duration, size: 50)
    return LibraryItem(
        id: id, libraryId: "lib", isMissing: isMissing, mediaType: .book, media: .book(book), size: 123)
}

private func progress(
    _ itemID: String = "li-1", episode: String? = nil, duration: Double = 1000, progress: Double = 0,
    currentTime: Double = 0, isFinished: Bool = false, ebookProgress: Double? = nil, finishedAt: Int? = nil,
    lastUpdate: Int = 1
) -> MediaProgress {
    MediaProgress(
        id: "p-\(itemID)-\(episode ?? "")", libraryItemId: itemID, episodeId: episode, duration: duration,
        progress: progress, currentTime: currentTime, isFinished: isFinished, ebookProgress: ebookProgress,
        lastUpdate: lastUpdate, finishedAt: finishedAt)
}

@MainActor
private func loadedModel(
    _ item: LibraryItem = makeBook(), cache: ProgressCache = ProgressCache(), episodeID: String? = nil
) async -> ItemDetailModel {
    let model = ItemDetailModel(
        itemID: item.id, episodeID: episodeID, service: FakeItemDetailService { _ in item }, cache: cache)
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

        cache.apply(progress(progress: 0, lastUpdate: 1))
        #expect(model.playButton == .play)

        cache.apply(progress(progress: 0.4, currentTime: 400, lastUpdate: 2))
        #expect(model.playButton == .resume)

        cache.apply(progress(progress: 1, currentTime: 1000, isFinished: true, lastUpdate: 3))
        #expect(model.playButton == .playAgain)

        // Ebook-only progress doesn't resume audio.
        cache.apply(progress(progress: 0, ebookProgress: 0.5, lastUpdate: 4))
        #expect(model.playButton == .play)
        #expect(model.progressFraction == 0.5)
    }

    @Test func playIsUnavailableWithoutAudio() async {
        let cache = ProgressCache()
        cache.apply(progress(progress: 0.4, currentTime: 400))
        #expect(await loadedModel(makeBook(trackCount: 0), cache: cache).playButton == .unavailable)
        #expect(await loadedModel(makeBook(duration: 0), cache: cache).playButton == .unavailable)
        #expect(await loadedModel(makeBook(isMissing: true), cache: cache).playButton == .unavailable)
        #expect(await loadedModel(makeBook(isMissing: true), cache: cache).isMissing)

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

    @Test func readNeedsAnEbookAndStaysDisabled() async {
        let withEbook = await loadedModel(makeBook(ebook: .epub))
        #expect(withEbook.hasEbook)
        #expect(withEbook.ebookFormat == .epub)
        #expect(!withEbook.isReadEnabled)

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

    @Test func anEpisodeModelReadsTheEpisodesKey() async {
        let cache = ProgressCache()
        let model = await loadedModel(cache: cache, episodeID: "ep-1")
        let changed = Locked(false)
        withObservationTracking {
            _ = model.progressFraction
        } onChange: {
            changed.value = true
        }

        cache.apply(progress(progress: 0.5))
        #expect(!changed.value)
        #expect(model.progressFraction == 0)

        cache.apply(progress(episode: "ep-1", progress: 0.5))
        #expect(changed.value)
        #expect(model.progressFraction == 0.5)
    }
}
