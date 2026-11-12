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
        // Trimmed: the converter starts a link's run at the space before it.
        let links = notes.runs.compactMap { run in
            run.link.map { (String(notes[run.range].characters).trimmingCharacters(in: .whitespaces), $0) }
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
