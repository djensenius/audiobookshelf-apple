import Foundation
import Testing

@testable import ABSAppModel

@MainActor
@Suite struct WindowRouteTests {
    private static let identity = SessionIdentity(
        connectionID: UUID(uuidString: "6F1E7C2A-3B4D-4E5F-8A9B-0C1D2E3F4A5B")!, userID: "user-1")

    /// One of each route that opens in a window of its own.
    nonisolated private static let opening: [Route] = [
        .item(id: "li_1"), .episode(itemID: "li_pod", episodeID: "ep_1"), .series(id: "se_1"), .author(id: "au_1"),
        .collection(id: "co_1"), .playlist(id: "pl_1"),
    ]

    /// One of each route that doesn't.
    nonisolated private static let staying: [Route] = [
        .narrator(name: "Kate Reading"), .libraryFilter(kind: .genres, value: "Fantasy"), .history(itemID: "li_1"),
        .localFolder(id: "lf_1"), .localItem(id: "lo_1"), .downloadQueue, .stats, .logs, .servers, .settings,
    ]

    /// The scene a screen opens from: the books library, on Series with a series open.
    private func source() -> Router {
        let router = Router(identity: Self.identity)
        router.snapshot = Router.Snapshot(
            serverID: router.serverID, userID: router.userID, selectedTab: .series, libraryID: "books",
            libraryKind: .book, paths: [.series: [.series(id: "se_9")]])
        return router
    }

    @Test(arguments: opening)
    func screensALinkOpensOpenInTheirOwnWindow(route: Route) throws {
        #expect(WindowRoute.opensInNewWindow(route))
        let window = try #require(WindowRoute(route, from: source()))
        #expect(window.route == route)
        #expect(window.serverID == "6F1E7C2A-3B4D-4E5F-8A9B-0C1D2E3F4A5B")
        #expect(window.userID == "user-1")
        #expect(window.libraryID == "books")
        #expect(window.libraryKind == .book)
    }

    @Test(arguments: staying)
    func otherScreensStayWhereTheyWerePushed(route: Route) {
        #expect(!WindowRoute.opensInNewWindow(route))
        #expect(WindowRoute(route, from: source()) == nil)
    }

    @Test(arguments: opening)
    func survivesTheWindowsValueEncoding(route: Route) throws {
        let window = try #require(WindowRoute(route, from: source()))
        let decoded = try JSONDecoder().decode(WindowRoute.self, from: JSONEncoder().encode(window))
        #expect(decoded == window)

        let withoutLibrary = WindowRoute(route: route, serverID: "server", userID: nil)
        #expect(
            try JSONDecoder().decode(WindowRoute.self, from: JSONEncoder().encode(withoutLibrary)) == withoutLibrary)
    }

    @Test func newWindowStartsAtTheScreenInTheSameLibrary() throws {
        let window = try #require(WindowRoute(.series(id: "se_1"), from: source()))
        let scene = SceneNavigation(identity: Self.identity)
        #expect(scene.restoreOnce(from: nil, window: window, isCompact: false, opening: nil))

        let router = scene.router
        #expect(router.selectedTab == .library)
        #expect(router.librarySection == nil)
        #expect(router[path: .library] == [.series(id: "se_1")])
        #expect(router[path: .series].isEmpty, "None of the opening scene's other screens")
        #expect(router.libraryID == "books")
        #expect(router.libraryKind == .book)
        // Saved as the window's own state from then on.
        let saved = Router(identity: Self.identity)
        saved.restore(from: scene.snapshotToSave)
        #expect(saved[path: .library] == [.series(id: "se_1")])
    }

    @Test func episodeOpensAboveItsPodcast() throws {
        let window = try #require(WindowRoute(.episode(itemID: "li_pod", episodeID: "ep_1"), from: source()))
        let router = Router(identity: Self.identity)
        router.restoreScene(from: nil, window: window, isCompact: false, opening: nil)
        #expect(router[path: .library] == [.item(id: "li_pod"), .episode(itemID: "li_pod", episodeID: "ep_1")])
    }

    @Test func savedStateWinsOverTheWindowsScreen() throws {
        // The window was opened for a screen, has moved on since, and is being restored.
        let saved = Router(identity: Self.identity)
        saved.selectedTab = .downloads
        let window = try #require(WindowRoute(.item(id: "li_1"), from: source()))

        let router = Router(identity: Self.identity)
        router.restoreScene(from: saved.snapshotData, window: window, isCompact: false, opening: nil)
        #expect(router.selectedTab == .downloads)
        #expect(router[path: .library].isEmpty)
        #expect(router.libraryID == nil)
    }

    @Test func screenOfAnotherAccountIsIgnored() {
        let router = Router(identity: Self.identity)
        let otherUser = WindowRoute(
            route: .item(id: "li_1"), serverID: router.serverID, userID: "user-2", libraryID: "books",
            libraryKind: .book)
        let otherServer = WindowRoute(
            route: .item(id: "li_1"), serverID: UUID().uuidString, userID: router.userID, libraryID: "books",
            libraryKind: .book)

        for window in [otherUser, otherServer] {
            router.restoreScene(from: nil, window: window, isCompact: false, opening: nil)
            #expect(router.selectedTab == .home)
            #expect(router[path: .library].isEmpty)
            #expect(router.libraryID == nil)
        }
    }

    @Test func linkOpensOnTopOfTheWindowsScreen() throws {
        let window = try #require(WindowRoute(.series(id: "se_1"), from: source()))
        let router = Router(identity: Self.identity)
        router.restoreScene(from: nil, window: window, isCompact: false, opening: DeepLink(.author(id: "au_1")))
        #expect(router.selectedTab == .library)
        #expect(router[path: .library] == [.series(id: "se_1"), .author(id: "au_1")])
    }
}
