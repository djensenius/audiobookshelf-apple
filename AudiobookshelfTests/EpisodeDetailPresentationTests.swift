import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import Foundation
import Testing

@testable import Audiobookshelf

/// Records the progress actions sent for the episode.
@MainActor
private final class RecordingEpisodeActions: ItemActionPerforming {
    var calls: [(String, ItemActionTarget)] = []

    func markFinished(_ target: ItemActionTarget) async throws { calls.append(("markFinished", target)) }
    func markNotFinished(_ target: ItemActionTarget) async throws { calls.append(("markNotFinished", target)) }
    func hideFromContinueListening(_ target: ItemActionTarget) async throws { calls.append(("hide", target)) }
    func discardProgress(_ target: ItemActionTarget) async throws { calls.append(("discard", target)) }
}

/// Serves the podcast until told to fail.
private actor SwitchablePodcastService: ItemDetailService {
    let item: ABSCore.LibraryItem
    private var error: (any Error)?

    init(item: ABSCore.LibraryItem) {
        self.item = item
    }

    func fail(with error: (any Error)?) {
        self.error = error
    }

    func item(id: String) async throws -> ABSCore.LibraryItem {
        if let error { throw error }
        return item
    }
}

/// Holds each podcast request until the test answers it, so a load can be seen in flight.
private actor HeldPodcastService: ItemDetailService {
    private var waiting: [CheckedContinuation<ABSCore.LibraryItem, any Error>] = []

    func item(id: String) async throws -> ABSCore.LibraryItem {
        try await withCheckedThrowingContinuation { waiting.append($0) }
    }

    func answer(_ result: Result<ABSCore.LibraryItem, any Error>) {
        waiting.removeFirst().resume(with: result)
    }

    /// Waits for the model's request to arrive.
    func waitForRequest() async {
        while waiting.isEmpty { await Task.yield() }
    }
}

/// Records the episodes Play starts.
@MainActor
private final class RecordedPlays {
    var starts: [(itemID: String, episodeID: String?, startTime: Double?)] = []
}

@MainActor
@Suite struct EpisodeDetailPresentationTests {
    private let locale = Locale(identifier: "en_US")
    private let podcast = PodcastDetailPreviewData.podcast

    /// The preview podcast with its progress (`pe_2` in progress, `pe_3` finished), loaded.
    private func loadedModel(
        episodeID: String, service: (any ItemDetailService)? = nil, cache: ProgressCache = ProgressCache()
    ) async -> EpisodeDetailModel {
        for progress in PodcastDetailPreviewData.progress { cache.apply(progress) }
        let detail = ItemDetailModel(
            itemID: podcast.id, service: service ?? PreviewItemDetailService(item: podcast, behavior: .succeed),
            cache: cache)
        await detail.load()
        return EpisodeDetailModel(detail: detail, episodeID: episodeID, cache: cache)
    }

    // MARK: Show notes

    @Test func showNotesKeepFormattingAndWebLinks() throws {
        let html = """
            <p>Guests: <b>Ada</b> &amp; <i>Grace</i>.</p>\
            <p>Read <a href="https://example.com/notes?id=1&amp;x=2">the notes</a> \
            or <a href="http://example.org">the archive</a>.</p>
            """
        let notes = try #require(EpisodeDetailPresentation.showNotes(html: html))
        #expect(String(notes.characters) == "Guests: Ada & Grace.\n\nRead the notes or the archive.")
        let links = notes.runs.compactMap { run in
            run.link.map { (String(notes[run.range].characters), $0) }
        }
        #expect(links.map(\.0) == ["the notes", "the archive"])
        #expect(
            links.map(\.1) == [
                URL(string: "https://example.com/notes?id=1&x=2"), URL(string: "http://example.org"),
            ])
        let bold = try #require(notes.range(of: "Ada"))
        #expect(notes[bold].inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
    }

    @Test func showNotesLoadNothingRemoteAndDropUnsafeLinks() throws {
        let html = """
            <p>Hello<img src="https://tracker.example/pixel.gif" alt="pixel"></p>\
            <script>fetch("https://tracker.example")</script><style>p { background: url(https://x.example) }</style>\
            <iframe src="https://player.example"></iframe>\
            <a href="javascript:alert(1)">script</a> <a href="file:///etc/passwd">file</a> \
            <a href="/relative">relative</a>
            """
        let notes = try #require(EpisodeDetailPresentation.showNotes(html: html))
        #expect(String(notes.characters) == "Hello\n\nscript file relative")
        // Negative controls: no image, link or other URL survives, so nothing can be fetched.
        #expect(notes.runs.allSatisfy { $0.link == nil && $0.imageURL == nil })
        #expect(!String(notes.characters).contains("tracker"))
    }

    @Test(arguments: [nil, "", "   ", "<p> </p><br>", "<img src=\"https://x.example/a.png\">"])
    func blankShowNotesShowNothing(html: String?) {
        #expect(EpisodeDetailPresentation.showNotes(html: html) == nil)
    }

    // MARK: Header

    @Test func detailLineShowsThePublishedDateAndDuration() {
        let episode = PodcastEpisode(id: "e", title: "E", publishedAt: 1_700_000_000_000, duration: 2_100)
        #expect(EpisodeDetailPresentation.detailLine(episode, locale: locale) == "Published Nov 14, 2023 · 35m")
        let durationOnly = PodcastEpisode(id: "e", title: "E", publishedAt: 0, duration: 3_600)
        #expect(EpisodeDetailPresentation.detailLine(durationOnly, locale: locale) == "1h")
        let neither = PodcastEpisode(id: "e", title: "E", duration: 0)
        #expect(EpisodeDetailPresentation.detailLine(neither, locale: locale) == nil)
    }

    // MARK: Actions

    @Test func playFollowsProgressAndNeedsAPlayer() async {
        let notStarted = await loadedModel(episodeID: "pe_1")
        let inProgress = await loadedModel(episodeID: "pe_2")
        let finished = await loadedModel(episodeID: "pe_3")
        func play(_ model: EpisodeDetailModel, canPlay: Bool = true, isGone: Bool = false)
            -> ItemDetailPlayPresentation
        {
            EpisodeDetailPresentation.play(for: model, canPlay: canPlay, isGone: isGone)
        }
        #expect(play(notStarted).titleKey == "ButtonPlay")
        #expect(play(inProgress).titleKey == "ButtonItemDetailResume")
        #expect(play(finished).titleKey == "ButtonItemDetailPlayAgain")
        #expect([notStarted, inProgress, finished].allSatisfy { play($0).isEnabled })
        // Negative controls: signed out (no `playItem`) or gone from the server.
        #expect(!play(inProgress, canPlay: false).isEnabled)
        #expect(!play(inProgress, isGone: true).isEnabled)
        // A finished episode starts over; others resume from the server's position.
        #expect(finished.playStartTime == 0)
        #expect(inProgress.playStartTime == nil)
    }

    @Test func playStartsThisEpisodeOverOnlyOnceFinished() async {
        let plays = RecordedPlays()
        let play = PlayItemAction { itemID, episodeID, startTime in
            plays.starts.append((itemID, episodeID, startTime))
        }
        for episodeID in ["pe_1", "pe_2", "pe_3"] {
            let model = await loadedModel(episodeID: episodeID)
            #expect(await EpisodeDetailPresentation.startPlayback(of: model, with: play) == nil)
        }
        #expect(plays.starts.map(\.itemID) == Array(repeating: podcast.id, count: 3))
        #expect(plays.starts.map(\.episodeID) == ["pe_1", "pe_2", "pe_3"])
        // Play Again on the finished `pe_3` starts at 0; the others resume (`nil`).
        #expect(plays.starts.map(\.startTime) == [nil, nil, 0])
    }

    @Test func aFailedStartIsReportedButACancelledOneIsnt() async {
        struct Failure: LocalizedError {
            var errorDescription: String? { "No route" }
        }
        let model = await loadedModel(episodeID: "pe_2")
        let failing = PlayItemAction { _, _, _ in throw Failure() }
        let cancelled = PlayItemAction { _, _, _ in throw CancellationError() }
        #expect(await EpisodeDetailPresentation.startPlayback(of: model, with: failing)?.message == "No route")
        #expect(await EpisodeDetailPresentation.startPlayback(of: model, with: cancelled) == nil)
    }

    @Test func aMissingPodcastSaysMissingAndCantPlay() async {
        let missing = ABSCore.LibraryItem(
            id: podcast.id, libraryId: podcast.libraryId, isMissing: true, mediaType: .podcast, media: podcast.media)
        let model = await loadedModel(
            episodeID: "pe_2", service: PreviewItemDetailService(item: missing, behavior: .succeed))
        let play = EpisodeDetailPresentation.play(for: model, canPlay: true, isGone: false)
        #expect(play.titleKey == "LabelMissing")
        #expect(!play.isEnabled)
        #expect(model.menuActions(canEditPlaylists: false, canShare: true, isGone: false) == [.share])
    }

    @Test func menuOffersTheFinishedToggleAndShare() async {
        let notStarted = await loadedModel(episodeID: "pe_1")
        let inProgress = await loadedModel(episodeID: "pe_2")
        let finished = await loadedModel(episodeID: "pe_3")
        func actions(_ model: EpisodeDetailModel, canShare: Bool = true) -> [ItemDetailMenuAction] {
            model.menuActions(canEditPlaylists: false, canShare: canShare, isGone: false)
        }
        #expect(actions(notStarted) == [.markFinished, .share])
        #expect(actions(inProgress) == [.markFinished, .discardProgress, .share])
        #expect(actions(finished) == [.markNotFinished, .discardProgress, .share])
        // Without the server's address there's nothing to share.
        #expect(actions(notStarted, canShare: false) == [.markFinished])
    }

    @Test func progressActionsTargetTheEpisode() async throws {
        let model = await loadedModel(episodeID: "pe_2")
        let summary = try #require(model.summary)
        let actions = RecordingEpisodeActions()
        for action in [ItemDetailMenuAction.markFinished, .markNotFinished, .discardProgress] {
            #expect(await ItemDetailMenuPresentation.perform(action, on: summary, actions: actions) == nil)
        }
        #expect(actions.calls.map(\.0) == ["markFinished", "markNotFinished", "discard"])
        #expect(actions.calls.allSatisfy { $0.1.libraryItemID == podcast.id && $0.1.episodeID == "pe_2" })
    }

    @Test func shareLinksToThePodcastUnderTheServersPath() throws {
        let server = try #require(URL(string: "https://abs.example.com/audiobookshelf"))
        #expect(
            EpisodeDetailPresentation.shareURL(serverURL: server, itemID: "li 1").absoluteString
                == "https://abs.example.com/audiobookshelf/item/li%201")
    }

    // MARK: Screen state

    /// Runs one load against `service`, checks the screen shows loading while it's in flight,
    /// answers it, and returns the screen afterwards.
    private func screenAfterLoad(
        _ model: EpisodeDetailModel, service: HeldPodcastService,
        answering result: Result<ABSCore.LibraryItem, any Error>
    ) async -> (inFlight: EpisodeDetailScreenState, after: EpisodeDetailScreenState) {
        let load = Task { await model.detail.load() }
        await service.waitForRequest()
        let inFlight = EpisodeDetailPresentation.screen(for: model)
        await service.answer(result)
        await load.value
        return (inFlight, EpisodeDetailPresentation.screen(for: model))
    }

    private func heldModel(episodeID: String) -> (EpisodeDetailModel, HeldPodcastService) {
        let service = HeldPodcastService()
        let cache = ProgressCache()
        let detail = ItemDetailModel(itemID: podcast.id, service: service, cache: cache)
        return (EpisodeDetailModel(detail: detail, episodeID: episodeID, cache: cache), service)
    }

    @Test func screenFollowsTheLoad() async {
        let (model, service) = heldModel(episodeID: "pe_2")
        #expect(EpisodeDetailPresentation.screen(for: model) == .loading)
        let first = await screenAfterLoad(model, service: service, answering: .failure(APIError.timedOut))
        #expect(first.inFlight == .loading)
        #expect(first.after == .failed)
        let retry = await screenAfterLoad(model, service: service, answering: .success(podcast))
        #expect(retry.inFlight == .loading)
        #expect(retry.after == .episode)
        // A refresh keeps the episode on screen, even one that answers 404 (its actions go off).
        let refresh = await screenAfterLoad(model, service: service, answering: .failure(APIError.notFound))
        #expect(refresh.inFlight == .episode)
        #expect(refresh.after == .episode)
    }

    @Test func aFirstLoadAnswering404IsNotFound() async {
        let (model, service) = heldModel(episodeID: "pe_2")
        let load = await screenAfterLoad(model, service: service, answering: .failure(APIError.notFound))
        #expect(load.after == .notFound)
    }

    @Test func retryFromNotFoundShowsLoadingAndATimedOutRetryFails() async {
        // The podcast loads without the episode: not found.
        let (model, service) = heldModel(episodeID: "pe_deleted")
        let first = await screenAfterLoad(model, service: service, answering: .success(podcast))
        #expect(first.after == .notFound)
        // Retry shows its spinner, not "not found".
        let timedOut = await screenAfterLoad(model, service: service, answering: .failure(APIError.timedOut))
        #expect(timedOut.inFlight == .loading)
        // A retry that times out failed; it doesn't say the episode is gone.
        #expect(timedOut.after == .failed)
        let found = await screenAfterLoad(model, service: service, answering: .success(podcast))
        #expect(found.inFlight == .loading)
        #expect(found.after == .notFound)
    }

    // MARK: Stale sessions

    @Test func aGonePodcastKeepsEpisodeActionsOffUntilItLoads() async {
        let service = SwitchablePodcastService(item: podcast)
        let model = await loadedModel(episodeID: "pe_2", service: service)
        var gone = ItemDetailGoneState()
        // What the menu offers and Play allows, as the screen computes them.
        func state() -> (actions: [ItemDetailMenuAction], canPlay: Bool) {
            let snapshot = ItemDetailGoneState.Snapshot(model: model.detail)
            gone.update(snapshot)
            let isGone = gone.isGone(snapshot)
            return (
                model.menuActions(canEditPlaylists: false, canShare: true, isGone: isGone),
                EpisodeDetailPresentation.play(for: model, canPlay: true, isGone: isGone).isEnabled
            )
        }
        #expect(state().actions == [.markFinished, .discardProgress, .share])
        #expect(state().canPlay)

        await service.fail(with: APIError.notFound)
        await model.detail.load()
        #expect(model.episode != nil)
        #expect(state().actions == [.share])
        #expect(!state().canPlay)

        // A retry that times out hides the 404, but the podcast is still known to be gone.
        await service.fail(with: APIError.timedOut)
        await model.detail.load()
        #expect(state().actions == [.share])
        #expect(!state().canPlay)

        await service.fail(with: nil)
        await model.detail.load()
        #expect(state().actions == [.markFinished, .discardProgress, .share])
        #expect(state().canPlay)
    }
}
