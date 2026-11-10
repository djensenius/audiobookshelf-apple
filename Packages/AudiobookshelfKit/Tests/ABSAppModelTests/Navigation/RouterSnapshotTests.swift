import Foundation
import Testing

@testable import ABSAppModel

@MainActor
@Suite struct RouterSnapshotTests {
    private func populatedRouter() -> Router {
        let router = Router(serverID: "server-1", userID: "user-1")
        router.selectLibrary(id: "books", mediaType: .book, supportedSections: AppTab.sections(for: .book))
        router.selectedTab = .library
        router.librarySection = .series
        router[path: .library] = [.series(id: "se_1"), .item(id: "li_1")]
        router[path: .account] = [.settings]
        router[path: .downloads] = [.localFolder(id: "lf_1"), .localItem(id: "local_1")]
        router[path: .home] = [.episode(itemID: "li_2", episodeID: "ep_1"), .history(itemID: "li_2")]
        router.isQueueInspectorPresented = true
        return router
    }

    @Test func jsonRoundTripRestoresTheScene() throws {
        let original = populatedRouter()
        let data = try JSONEncoder().encode(original.snapshot)

        let restored = Router(serverID: "server-1", userID: "user-1")
        restored.snapshot = try JSONDecoder().decode(Router.Snapshot.self, from: data)

        #expect(restored.snapshot == original.snapshot)
        #expect(restored.selectedTab == .library)
        #expect(restored.libraryID == "books")
        #expect(restored.libraryKind == .book)
        #expect(restored.librarySection == .series)
        #expect(restored[path: .library] == [.series(id: "se_1"), .item(id: "li_1")])
        #expect(restored[path: .downloads] == [.localFolder(id: "lf_1"), .localItem(id: "local_1")])
        #expect(restored.isQueueInspectorPresented == true)
    }

    @Test func jsonUsesTabNamesAsKeys() throws {
        let data = try JSONEncoder().encode(populatedRouter().snapshot)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let paths = try #require(object["paths"] as? [String: Any])
        #expect(Set(paths.keys) == ["library", "account", "downloads", "home"])
    }

    @Test func fullPlayerPresentationIsNeverStored() throws {
        let router = populatedRouter()
        router.isFullPlayerPresented = true
        let data = try JSONEncoder().encode(router.snapshot)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("FullPlayer"))

        let restored = Router(serverID: "server-1", userID: "user-1")
        restored.snapshot = try JSONDecoder().decode(Router.Snapshot.self, from: data)
        #expect(restored.isFullPlayerPresented == false)

        // Restoring doesn't dismiss a player the scene is already showing either.
        restored.isFullPlayerPresented = true
        restored.snapshot = router.snapshot
        #expect(restored.isFullPlayerPresented == true)
    }

    @Test(arguments: [("server-2", "user-1"), ("server-1", "user-2"), (nil, nil)] as [(String?, String?)])
    func mismatchedIdentityIsDiscarded(serverID: String?, userID: String?) {
        let snapshot = populatedRouter().snapshot
        let router = Router(serverID: serverID, userID: userID)
        router.selectedTab = .downloads
        router[path: .downloads] = [.downloadQueue]

        router.snapshot = snapshot

        #expect(router.snapshot == Router.Snapshot(serverID: serverID, userID: userID))
        #expect(router.paths.isEmpty)
    }

    @Test func librarySectionIsValidatedAgainstTheLibraryKind() {
        let router = Router(serverID: "s", userID: "u")
        router.snapshot = Router.Snapshot(
            serverID: "s", userID: "u", selectedTab: .series, libraryID: "podcasts", libraryKind: .podcast,
            librarySection: .authors, paths: [.series: [.item(id: "li_1")], .home: [.item(id: "li_2")]]
        )

        #expect(router.selectedTab == .library)
        #expect(router.librarySection == nil)
        #expect(router[path: .series] == [])
        #expect(router[path: .home] == [.item(id: "li_2")])
    }

    @Test func supportedSectionIsRestored() {
        let router = Router(serverID: "s", userID: "u")
        router.snapshot = Router.Snapshot(
            serverID: "s", userID: "u", selectedTab: .latest, libraryID: "podcasts", libraryKind: .podcast,
            librarySection: .playlists, paths: [.latest: [.item(id: "li_1")]]
        )

        #expect(router.selectedTab == .latest)
        #expect(router.librarySection == .playlists)
        #expect(router[path: .latest] == [.item(id: "li_1")])
    }

    @Test func nonSectionLibrarySectionFallsBackToTheGrid() {
        let router = Router(serverID: "s", userID: "u")
        router.snapshot = Router.Snapshot(
            serverID: "s", userID: "u", libraryID: "books", libraryKind: .book, librarySection: .downloads
        )
        #expect(router.librarySection == nil)
    }

    @Test func unknownLibraryKindRestoresNoSection() {
        let router = Router(serverID: "s", userID: "u")
        router.snapshot = Router.Snapshot(
            serverID: "s", userID: "u", selectedTab: .series, libraryID: "x", librarySection: .series
        )
        #expect(router.selectedTab == .library)
        #expect(router.librarySection == nil)
    }

    @Test func restoredLibraryKeepsPathsWhenTheSceneConfirmsIt() {
        let router = Router(serverID: "server-1", userID: "user-1")
        router.snapshot = populatedRouter().snapshot

        // The scene confirms the restored library once libraries load; paths stay.
        router.selectLibrary(id: "books", mediaType: .book, supportedSections: AppTab.sections(for: .book))

        #expect(router[path: .library] == [.series(id: "se_1"), .item(id: "li_1")])
        #expect(router.librarySection == .series)
    }

    @Test func routesDecodeFromTheirStoredForm() throws {
        let routes: [Route] = [
            .item(id: "a"), .episode(itemID: "a", episodeID: "b"), .series(id: "c"), .author(id: "d"),
            .narrator(name: "e"), .collection(id: "f"), .playlist(id: "g"), .history(itemID: "h"),
            .localFolder(id: "i"), .localItem(id: "j"), .downloadQueue, .stats, .logs, .servers, .settings,
        ]
        let data = try JSONEncoder().encode(routes)
        #expect(try JSONDecoder().decode([Route].self, from: data) == routes)
    }
}
