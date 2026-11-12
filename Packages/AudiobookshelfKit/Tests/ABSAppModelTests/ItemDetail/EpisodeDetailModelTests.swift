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

/// Replies to successive loads in order.
private actor Replies {
    private var results: [Result<LibraryItem, any Error>]

    init(_ results: [Result<LibraryItem, any Error>]) { self.results = results }

    func next() throws -> LibraryItem { try results.removeFirst().get() }
}

private func makePodcast(
    title: String = " The Show ",
    episodes: [PodcastEpisode] = [
        PodcastEpisode(id: "e1", title: "One", description: "<p>Notes</p>", duration: 600),
        PodcastEpisode(id: "e2", title: "Two", description: "  ", duration: 900),
    ], isMissing: Bool = false, isInvalid: Bool = false
) -> LibraryItem {
    let podcast = Podcast(
        id: "pod", libraryItemId: "li-pod", metadata: PodcastMetadata(title: title), episodes: episodes)
    return LibraryItem(
        id: "li-pod", libraryId: "lib", isMissing: isMissing, isInvalid: isInvalid, mediaType: .podcast,
        media: .podcast(podcast))
}

private func progress(
    _ episodeID: String = "e1", currentTime: Double = 0, isFinished: Bool = false, finishedAt: Int? = nil
) -> MediaProgress {
    MediaProgress(
        id: "p-\(episodeID)", libraryItemId: "li-pod", episodeId: episodeID, duration: 600,
        progress: isFinished ? 1 : currentTime / 600, currentTime: currentTime, isFinished: isFinished, lastUpdate: 1,
        finishedAt: finishedAt)
}

@MainActor
private func makeModel(
    episodeID: String = "e1", cache: ProgressCache = ProgressCache(),
    handler: @escaping @Sendable (String) async throws -> LibraryItem = { _ in makePodcast() }
) -> EpisodeDetailModel {
    let detail = ItemDetailModel(itemID: "li-pod", service: FakeItemDetailService(handler: handler), cache: cache)
    return EpisodeDetailModel(detail: detail, episodeID: episodeID, cache: cache)
}

@MainActor
@Suite struct EpisodeDetailModelTests {
    @Test func readsTheEpisodeFromTheLoadedPodcast() async throws {
        let model = makeModel()
        #expect(model.episode == nil)
        #expect(!model.isEpisodeMissing)
        #expect(model.summary == nil)
        #expect(model.playButton == .unavailable)

        await model.detail.load()
        #expect(model.episode?.title == "One")
        #expect(model.podcastTitle == "The Show")
        #expect(model.showNotesHTML == "<p>Notes</p>")
        #expect(!model.isEpisodeMissing)
        let summary = try #require(model.summary)
        #expect(summary.itemID == "li-pod")
        #expect(summary.episodeID == "e1")
        #expect(model.status == .notStarted(duration: 600))
        #expect(model.playButton == .play)
    }

    @Test func blankShowNotesAreNil() async {
        let model = makeModel(episodeID: "e2")
        await model.detail.load()
        #expect(model.episode?.title == "Two")
        #expect(model.showNotesHTML == nil)
    }

    @Test func anEpisodeTheLoadedPodcastLacksIsMissing() async {
        let model = makeModel(episodeID: "gone")
        await model.detail.load()
        #expect(model.episode == nil)
        #expect(model.isEpisodeMissing)
        #expect(model.summary == nil)
        #expect(model.playButton == .unavailable)
        #expect(model.menuActions(canEditPlaylists: true, canShare: true, isGone: false).isEmpty)
    }

    @Test func playAndProgressFollowThisEpisodesProgressOnly() async {
        let cache = ProgressCache()
        let model = makeModel(cache: cache)
        await model.detail.load()
        // Negative control: another episode's progress, or the podcast's, doesn't count.
        cache.apply(progress("e2", currentTime: 300))
        #expect(model.playButton == .play)
        #expect(model.progressFraction == 0)

        cache.apply(progress(currentTime: 150))
        #expect(model.playButton == .resume)
        #expect(model.playStartTime == nil)
        #expect(model.progressFraction == 0.25)
        #expect(model.timeRemaining == 450)
        #expect(model.finishedAt == nil)

        cache.apply(progress(currentTime: 600, isFinished: true, finishedAt: 1_700_000_000_000))
        #expect(model.playButton == .playAgain)
        #expect(model.playStartTime == 0)
        #expect(model.isFinished)
        #expect(model.timeRemaining == nil)
        #expect(model.finishedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test(arguments: [(true, false), (false, true)])
    func aMissingOrInvalidPodcastCantPlayOrChangeProgress(isMissing: Bool, isInvalid: Bool) async {
        let model = makeModel { _ in makePodcast(isMissing: isMissing, isInvalid: isInvalid) }
        await model.detail.load()
        #expect(model.episode != nil)
        #expect(model.playButton == .unavailable)
        #expect(model.menuActions(canEditPlaylists: true, canShare: true, isGone: false) == [.share])
    }

    @Test func menuOffersTheFinishedToggleDiscardAndShare() async {
        let cache = ProgressCache()
        let model = makeModel(cache: cache)
        #expect(model.menuActions(canEditPlaylists: false, canShare: true, isGone: false).isEmpty)
        await model.detail.load()

        #expect(model.menuActions(canEditPlaylists: false, canShare: true, isGone: false) == [.markFinished, .share])
        #expect(model.menuActions(canEditPlaylists: false, canShare: false, isGone: false) == [.markFinished])
        #expect(
            model.menuActions(canEditPlaylists: true, canShare: true, isGone: false) == [
                .markFinished, .addToPlaylist, .share,
            ])
        #expect(model.confirmationMessageKey(for: .markFinished) == nil)

        cache.apply(progress(currentTime: 150))
        #expect(
            model.menuActions(canEditPlaylists: false, canShare: true, isGone: false) == [
                .markFinished, .discardProgress, .share,
            ])
        #expect(model.confirmationMessageKey(for: .markFinished) == "MessageConfirmMarkAsFinished")
        #expect(model.confirmationMessageKey(for: .discardProgress) == "MessageConfirmDiscardProgress")

        cache.apply(progress(currentTime: 600, isFinished: true))
        #expect(
            model.menuActions(canEditPlaylists: false, canShare: true, isGone: false) == [
                .markNotFinished, .discardProgress, .share,
            ])
        #expect(model.confirmationMessageKey(for: .markNotFinished) == nil)

        // Gone from the server: only Share.
        #expect(model.menuActions(canEditPlaylists: true, canShare: true, isGone: true) == [.share])
    }

    @Test func aReloadThatAnswers404KeepsTheEpisodeButDropsItsActions() async {
        let replies = Replies([.success(makePodcast()), .failure(APIError.notFound)])
        let model = makeModel { _ in try await replies.next() }
        await model.detail.load()
        #expect(model.isPresent(isGone: false))

        await model.detail.load()
        #expect(model.episode?.title == "One")
        #expect(!model.isPresent(isGone: false))
        #expect(model.menuActions(canEditPlaylists: false, canShare: true, isGone: false) == [.share])
    }

    @Test func aReloadWithoutTheEpisodeMakesItMissing() async {
        let replies = Replies([
            .success(makePodcast()), .success(makePodcast(episodes: [PodcastEpisode(id: "e2", title: "Two")])),
        ])
        let model = makeModel { _ in try await replies.next() }
        await model.detail.load()
        #expect(!model.isEpisodeMissing)

        await model.detail.load()
        #expect(model.isEpisodeMissing)
        #expect(model.summary == nil)
        #expect(model.menuActions(canEditPlaylists: false, canShare: true, isGone: false).isEmpty)
    }

    @Test func aLateReplyToAnOlderLoadIsDropped() async throws {
        let gate = GatedCalls<String, LibraryItem>()
        var calls = gate.calls.makeAsyncIterator()
        let model = makeModel { id in try await gate.call(id) }

        let first = Task { await model.detail.load() }
        let firstCall = try #require(await calls.next())
        let second = Task { await model.detail.load() }
        let secondCall = try #require(await calls.next())

        secondCall.reply.resume(returning: makePodcast(episodes: [PodcastEpisode(id: "e1", title: "New")]))
        await second.value
        #expect(model.episode?.title == "New")

        // The older load answers last, without the episode; the screen keeps the newer one.
        firstCall.reply.resume(returning: makePodcast(episodes: []))
        await first.value
        #expect(model.episode?.title == "New")
        #expect(!model.isEpisodeMissing)
        #expect(model.menuActions(canEditPlaylists: false, canShare: false, isGone: false) == [.markFinished])
    }
}
