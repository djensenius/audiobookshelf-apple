import ABSAppModel
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
        isPlaying: Bool = false, isPlayable: Bool = true
    ) -> PlayLinkResolution {
        PlayLinkConfirmationPresentation.resolve(
            link: PlayLinkConfirmationPresentation.link(for: route, in: router, owner: .library), title: "Dune",
            isPlayable: isPlayable, canPlay: true, routerServerID: router.serverID, activeServerID: active,
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
        #expect(await PlayLinkConfirmationPresentation.confirm(prompt, with: plays.action) == nil)
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
        _ = await PlayLinkConfirmationPresentation.confirm(prompt, with: plays.action)
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
        _ = await PlayLinkConfirmationPresentation.confirm(prompt, with: plays.action)
        _ = await PlayLinkConfirmationPresentation.confirm(prompt, atCurrentPosition: true, with: plays.action)
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

        #expect(PlayLinkConfirmationPresentation.link(for: route, in: router, owner: .home) == nil)
        router.isFullPlayerPresented = true
        #expect(PlayLinkConfirmationPresentation.link(for: route, in: router, owner: .library) == nil)
        router.isFullPlayerPresented = false
        router.selectedTab = .home
        #expect(PlayLinkConfirmationPresentation.link(for: route, in: router, owner: .library) == nil)
        router.selectedTab = .library
        #expect(PlayLinkConfirmationPresentation.link(for: route, in: router, owner: .library) == Self.book)
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
