import ABSAPI
import ABSAppModel
import ABSCore
import ABSData
import Foundation
import Testing

@testable import Audiobookshelf

/// The play-link confirmation on item and episode screens (#577): when it asks, what Confirm
/// plays, and that Cancel, an account mismatch and media already playing never play.
@MainActor
@Suite struct PlayLinkConfirmationTests {
    private static let server = UUID(uuidString: "6F1E7C2A-3B4D-4E5F-8A9B-0C1D2E3F4A5B")!
    private static let other = UUID(uuidString: "0A1B2C3D-4E5F-4061-8293-A4B5C6D7E8F9")!
    private static let locale = Locale(identifier: "en_US")
    private static let book = PlayLink(itemID: "li_1", startTime: 5_025)
    private static let episode = PlayLink(itemID: "li_2", episodeID: "ep_1", startTime: 90)

    /// A scene router on `server` that has opened `link`.
    private func router(opening link: PlayLink, serverID: UUID = server) -> Router {
        let router = Router(serverID: serverID.uuidString, userID: "user-1")
        router.selectLibrary(id: "books", kind: .book, supportedSections: AppTab.sections(for: .book))
        router.open(DeepLink(.play(link)))
        return router
    }

    /// What the screen for `route` resolves on `router`, signed in to `active`.
    private func resolve(
        _ route: Route, on router: Router, active: UUID? = server, nowPlaying: MediaKey? = nil,
        isPlaying: Bool = false, isPlayable: Bool = true, screen: PlayLinkScreen? = nil
    ) -> PlayLinkResolution {
        PlayLinkConfirmationPresentation.resolve(
            link: PlayLinkConfirmationPresentation.link(for: route, in: router, owner: .library, isVisible: true),
            title: screen == nil ? "Dune" : screen?.title,
            isPlayable: screen?.isPlayable ?? isPlayable, canPlay: true, routerServerID: router.serverID,
            activeServerID: active,
            nowPlaying: nowPlaying, isPlaying: isPlaying, locale: Self.locale)
    }

    /// Records the plays a confirmation starts.
    @MainActor private final class Plays {
        var started: [(itemID: String, episodeID: String?, startTime: Double?)] = []

        var action: PlayItemAction {
            PlayItemAction { [self] itemID, episodeID, startTime in
                started.append((itemID, episodeID, startTime))
            }
        }
    }

    @Test func confirmPlaysFromTheLinksPosition() async throws {
        let router = router(opening: Self.book)

        let resolution = resolve(.item(id: "li_1"), on: router)
        let prompt = try #require(PlayLinkConfirmationPresentation.take(resolution, from: router))

        #expect(prompt.message == "Play \"Dune\" from 1:23:45?")
        #expect(prompt.confirmKey == "ButtonPlay")
        #expect(!prompt.offersCurrentPosition)
        let plays = Plays()
        #expect(await PlayLinkConfirmationPresentation.confirm(prompt, in: router, with: plays.action) == nil)
        #expect(plays.started.count == 1)
        #expect(plays.started.first?.itemID == "li_1")
        #expect(plays.started.first?.episodeID == nil)
        #expect(plays.started.first?.startTime == 5_025)
    }

    @Test func episodeLinkAsksOnTheEpisodeScreenOnly() async throws {
        let router = router(opening: Self.episode)

        #expect(resolve(.item(id: "li_2"), on: router) == .wait)
        let prompt = try #require(
            PlayLinkConfirmationPresentation.take(
                resolve(.episode(itemID: "li_2", episodeID: "ep_1"), on: router), from: router))

        let plays = Plays()
        _ = await PlayLinkConfirmationPresentation.confirm(prompt, in: router, with: plays.action)
        #expect(plays.started.first?.episodeID == "ep_1")
        #expect(plays.started.first?.startTime == 90)
    }

    @Test func askingDropsThePendingLinkSoCancelLeavesNothing() {
        let router = router(opening: Self.book)

        let prompt = PlayLinkConfirmationPresentation.take(resolve(.item(id: "li_1"), on: router), from: router)

        #expect(prompt != nil)
        #expect(router.pendingPlayLink == nil)
        // Cancel only closes the alert: the screen doesn't ask again and nothing plays.
        #expect(resolve(.item(id: "li_1"), on: router) == .wait)
    }

    @Test func accountMismatchNeverAsks() {
        // The scene's router belongs to another connection than the active one (mid-switch).
        let router = router(opening: Self.book, serverID: Self.other)

        #expect(resolve(.item(id: "li_1"), on: router) == .wait)
        #expect(PlayLinkConfirmationPresentation.take(.wait, from: router) == nil)
        #expect(router.pendingPlayLink == Self.book)
        // Signed out: no active connection.
        #expect(resolve(.item(id: "li_1"), on: router, active: nil) == .wait)
    }

    @Test func mediaPlayingOnAnotherAccountDoesntCountAsLoaded() {
        let router = router(opening: Self.book)
        let elsewhere = MediaKey(serverConnectionID: Self.other, libraryItemId: "li_1")

        guard case .ask(let prompt) = resolve(.item(id: "li_1"), on: router, nowPlaying: elsewhere, isPlaying: true)
        else {
            Issue.record("expected a Play prompt")
            return
        }
        #expect(!prompt.isResume)
    }

    @Test func itemAlreadyPlayingOpensOnlyAndDropsTheLink() {
        let router = router(opening: Self.book)
        let playing = MediaKey(serverConnectionID: Self.server, libraryItemId: "li_1")

        let resolution = resolve(.item(id: "li_1"), on: router, nowPlaying: playing, isPlaying: true)

        #expect(resolution == .dismiss)
        #expect(PlayLinkConfirmationPresentation.take(resolution, from: router) == nil)
        #expect(router.pendingPlayLink == nil)
    }

    @Test func pausedItemAsksToResumeFromTheLinkOrWhereItIs() async throws {
        let router = router(opening: Self.book)
        let paused = MediaKey(serverConnectionID: Self.server, libraryItemId: "li_1")

        let prompt = try #require(
            PlayLinkConfirmationPresentation.take(
                resolve(.item(id: "li_1"), on: router, nowPlaying: paused, isPlaying: false), from: router))

        #expect(prompt.isResume)
        #expect(prompt.message == "Resume \"Dune\" from 1:23:45?")
        #expect(prompt.confirmKey == "ButtonItemDetailResume")
        #expect(prompt.offersCurrentPosition)
        let plays = Plays()
        _ = await PlayLinkConfirmationPresentation.confirm(prompt, in: router, with: plays.action)
        _ = await PlayLinkConfirmationPresentation.confirm(
            prompt, atCurrentPosition: true, in: router, with: plays.action)
        #expect(plays.started.map(\.startTime) == [5_025, nil])
    }

    @Test func nothingToPlayDropsTheLink() {
        let router = router(opening: PlayLink(itemID: "li_1"))

        let resolution = resolve(.item(id: "li_1"), on: router, isPlayable: false)

        #expect(resolution == .dismiss)
        _ = PlayLinkConfirmationPresentation.take(resolution, from: router)
        #expect(router.pendingPlayLink == nil)
    }

    @Test func onlyTheLibraryTabsUncoveredScreenAsks() {
        let router = router(opening: Self.book)
        let route = Route.item(id: "li_1")

        #expect(PlayLinkConfirmationPresentation.link(for: route, in: router, owner: .home, isVisible: true) == nil)
        router.isFullPlayerPresented = true
        #expect(PlayLinkConfirmationPresentation.link(for: route, in: router, owner: .library, isVisible: true) == nil)
        router.isFullPlayerPresented = false
        router.selectedTab = .home
        #expect(PlayLinkConfirmationPresentation.link(for: route, in: router, owner: .library, isVisible: true) == nil)
        router.selectedTab = .library
        #expect(
            PlayLinkConfirmationPresentation.link(for: route, in: router, owner: .library, isVisible: true) == Self.book
        )
        // Covered or gone from the screen (between `onDisappear` and `onAppear`).
        #expect(PlayLinkConfirmationPresentation.link(for: route, in: router, owner: .library, isVisible: false) == nil)
    }

    @Test func aCoveredCopyOfTheItemFromBeforeTheLinkNeverTakesIt() {
        // Item A is already loaded lower in the path when a link pushes a second copy on top.
        let router = Router(serverID: Self.server.uuidString, userID: "user-1")
        router.selectLibrary(id: "books", kind: .book, supportedSections: AppTab.sections(for: .book))
        let route = Route.item(id: "li_1")
        router[path: .library] = [route, .series(id: "se_1")]
        router.open(DeepLink(.play(Self.book)))
        #expect(router[path: .library] == [route, .series(id: "se_1"), route])

        // Both copies match the route; only the visible one on top gets the link.
        let covered = PlayLinkConfirmationPresentation.link(for: route, in: router, owner: .library, isVisible: false)
        #expect(covered == nil)
        #expect(PlayLinkConfirmationPresentation.take(.wait, from: router) == nil)
        #expect(router.pendingPlayLink == Self.book)
        let visible = PlayLinkConfirmationPresentation.link(for: route, in: router, owner: .library, isVisible: true)
        #expect(visible == Self.book)
    }

    // MARK: Screen states

    /// The item screen for `item` once `behavior`'s load has run.
    private func itemModel(
        _ item: ABSCore.LibraryItem = ItemDetailPreviewData.book, behavior: PreviewItemDetailService.Behavior
    ) async -> ItemDetailModel {
        let model = ItemDetailModel(
            itemID: item.id, service: PreviewItemDetailService(item: item, behavior: behavior), cache: ProgressCache())
        await model.load()
        return model
    }

    @Test func itemScreenWaitsWhileLoadingAndDismissesWhenTheLoadEndsWithoutTheBook() async throws {
        let book = ItemDetailPreviewData.book
        let unloaded = ItemDetailModel(
            itemID: book.id, service: PreviewItemDetailService(item: book, behavior: .succeed), cache: ProgressCache())
        #expect(PlayLinkScreen.item(unloaded).title == nil)
        #expect(!PlayLinkScreen.item(unloaded).isPlayable)

        let model = await itemModel(behavior: .succeed)
        let loaded = PlayLinkScreen.item(model)
        #expect(loaded.title == model.details?.title)
        #expect(loaded.title != nil)
        #expect(loaded.isPlayable)

        for behavior in [PreviewItemDetailService.Behavior.notFound, .fail] {
            let screen = PlayLinkScreen.item(await itemModel(behavior: behavior))
            #expect(screen.title == "")
            #expect(!screen.isPlayable)
            let router = router(opening: Self.book)
            let resolution = resolve(.item(id: "li_1"), on: router, screen: screen)
            #expect(resolution == .dismiss)
            _ = PlayLinkConfirmationPresentation.take(resolution, from: router)
            #expect(router.pendingPlayLink == nil)
        }

        // A podcast's own screen has nothing to play.
        #expect(!PlayLinkScreen.item(await itemModel(PodcastDetailPreviewData.podcast, behavior: .succeed)).isPlayable)
    }

    /// The episode screen for `episodeID` of the preview podcast once `behavior`'s load has run.
    private func episodeModel(
        _ episodeID: String, behavior: PreviewItemDetailService.Behavior = .succeed
    ) async -> EpisodeDetailModel {
        let detail = await itemModel(PodcastDetailPreviewData.podcast, behavior: behavior)
        return EpisodeDetailModel(detail: detail, episodeID: episodeID, cache: ProgressCache())
    }

    @Test func episodeScreenDismissesALinkToAnEpisodeThePodcastLacks() async throws {
        let episode = await episodeModel("pe_2")
        let loaded = PlayLinkScreen.episode(episode)
        #expect(loaded.title == episode.episode?.title)
        #expect(loaded.title != nil)
        #expect(loaded.isPlayable)

        // The podcast loaded without the episode, or didn't load.
        for model in [await episodeModel("pe_missing"), await episodeModel("pe_2", behavior: .notFound)] {
            let screen = PlayLinkScreen.episode(model)
            #expect(screen.title == "")
            #expect(!screen.isPlayable)
            let link = PlayLink(itemID: "li_2", episodeID: model.episodeID, startTime: 90)
            let router = router(opening: link)
            let resolution = resolve(.episode(itemID: "li_2", episodeID: model.episodeID), on: router, screen: screen)
            #expect(resolution == .dismiss)
            _ = PlayLinkConfirmationPresentation.take(resolution, from: router)
            #expect(router.pendingPlayLink == nil)
        }
    }

    /// Serves `item`, or fails with the error the test sets.
    private actor ScriptedItemService: ItemDetailService {
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

    /// Follows `screen()` through the confirmation's remembered gone state, as the modifier
    /// does: whether a link would find something to play now, then records the snapshot.
    @MainActor private final class GoneFollower {
        var state = ItemDetailGoneState()

        func isPlayable(_ screen: PlayLinkScreen) -> Bool {
            let isPlayable = screen.isPlayable(given: state)
            if let gone = screen.gone { state.update(gone) }
            return isPlayable
        }
    }

    @Test func aBookGoneFromTheServerPlaysNoLinkUntilAReloadSucceeds() async throws {
        let book = ItemDetailPreviewData.book
        let service = ScriptedItemService(item: book)
        let model = ItemDetailModel(itemID: book.id, service: service, cache: ProgressCache())
        let follower = GoneFollower()
        await model.load()
        #expect(follower.isPlayable(.item(model)))

        // A refresh answers 404: the book stays on screen with Play disabled, and so does the link.
        await service.fail(with: APIError.notFound)
        await model.load()
        #expect(model.details != nil)
        #expect(PlayLinkScreen.item(model).isPlayable)
        #expect(!follower.isPlayable(.item(model)))
        let router = router(opening: Self.book)
        let resolution = resolve(
            .item(id: "li_1"), on: router, isPlayable: follower.isPlayable(.item(model)))
        #expect(resolution == .dismiss)

        // A retry that fails another way hides the 404, but the book is still gone.
        await service.fail(with: APIError.timedOut)
        await model.load()
        #expect(!follower.isPlayable(.item(model)))

        await service.fail(with: nil)
        await model.load()
        #expect(follower.isPlayable(.item(model)))
    }

    @Test func anEpisodeOfAPodcastGoneFromTheServerPlaysNoLink() async throws {
        let service = ScriptedItemService(item: PodcastDetailPreviewData.podcast)
        let detail = ItemDetailModel(
            itemID: PodcastDetailPreviewData.podcast.id, service: service, cache: ProgressCache())
        let model = EpisodeDetailModel(detail: detail, episodeID: "pe_2", cache: ProgressCache())
        let follower = GoneFollower()
        await detail.load()
        #expect(follower.isPlayable(.episode(model)))

        await service.fail(with: APIError.notFound)
        await detail.load()
        #expect(model.episode != nil)
        #expect(!follower.isPlayable(.episode(model)))
        await service.fail(with: APIError.timedOut)
        await detail.load()
        #expect(!follower.isPlayable(.episode(model)))

        await service.fail(with: nil)
        await detail.load()
        #expect(follower.isPlayable(.episode(model)))
    }

    @Test func newerNavigationSupersedesAnAskedPrompt() async throws {
        let router = router(opening: Self.book)
        let prompt = try #require(
            PlayLinkConfirmationPresentation.take(resolve(.item(id: "li_1"), on: router), from: router))
        #expect(PlayLinkConfirmationPresentation.isCurrent(prompt, in: router))

        // `item/li_1` keeps the same screen on top, but the question it was asked under is gone.
        router.open(DeepLink(.item(id: "li_1", episodeID: nil)))
        #expect(router[path: .library] == [.item(id: "li_1")])
        #expect(!PlayLinkConfirmationPresentation.isCurrent(prompt, in: router))
        let plays = Plays()
        #expect(await PlayLinkConfirmationPresentation.confirm(prompt, in: router, with: plays.action) == nil)
        #expect(plays.started.isEmpty)

        // So does a change to the Library path, such as pushing a screen and popping back.
        let next = PlayLink(itemID: "li_1", startTime: 30)
        router.open(DeepLink(.play(next)))
        let current = try #require(
            PlayLinkConfirmationPresentation.take(resolve(.item(id: "li_1"), on: router), from: router))
        router[path: .library] += [.series(id: "se_1")]
        router[path: .library].removeLast()
        _ = await PlayLinkConfirmationPresentation.confirm(current, in: router, with: plays.action)
        #expect(plays.started.isEmpty)
    }

    @Test func handoffPlayerActivityAsksLikeAPlayURL() throws {
        // A continued player activity becomes a `play/` link with the position (#219).
        let link = try #require(
            DeepLink(handoff: ["item": "li_1", "position": 5_025.0]))
        let router = Router(serverID: Self.server.uuidString, userID: "user-1")
        router.selectLibrary(id: "books", kind: .book, supportedSections: AppTab.sections(for: .book))
        router.open(link)

        guard case .ask(let prompt) = resolve(.item(id: "li_1"), on: router) else {
            Issue.record("expected a Play prompt")
            return
        }
        #expect(prompt.link.startTime == 5_025)
    }
}
