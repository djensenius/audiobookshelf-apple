import Foundation
import Testing

@testable import ABSAppModel

@MainActor
@Suite struct RouterSnapshotTests {
    private func populatedRouter() -> Router {
        let router = Router(serverID: "server-1", userID: "user-1")
        router.selectLibrary(id: "books", kind: .book, supportedSections: AppTab.sections(for: .book))
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

    @Test(
        arguments: [("server-2", "user-1"), ("server-1", "user-2"), ("server-1", nil), (nil, nil)]
            as [(String?, String?)])
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
        router.selectLibrary(id: "books", kind: .book, supportedSections: AppTab.sections(for: .book))

        #expect(router[path: .library] == [.series(id: "se_1"), .item(id: "li_1")])
        #expect(router.librarySection == .series)
    }

    @Test func routesRoundTrip() throws {
        let routes: [Route] = [
            .item(id: "a"), .episode(itemID: "a", episodeID: "b"), .series(id: "c"), .author(id: "d"),
            .narrator(name: "e"), .collection(id: "f"), .playlist(id: "g"), .history(itemID: "h"),
            .localFolder(id: "i"), .localItem(id: "j"), .downloadQueue, .stats, .logs, .servers, .settings,
        ]
        let data = try JSONEncoder().encode(routes)
        #expect(try JSONDecoder().decode([Route].self, from: data) == routes)
    }

    /// Pins the stored wire format of `Snapshot`, `AppTab` and `Route`. Changing a case name or
    /// label breaks scenes saved by earlier builds, so this literal must not be edited.
    @Test func goldenSnapshotDecodes() throws {
        let json = """
            {
              "serverID": "server-1", "userID": "user-1", "selectedTab": "addPodcast",
              "libraryID": "podcasts", "libraryKind": "podcast", "librarySection": "latest",
              "isQueueInspectorPresented": true,
              "paths": {
                "home": [{"item": {"id": "a"}}, {"episode": {"itemID": "a", "episodeID": "b"}}],
                "library": [{"series": {"id": "c"}}, {"author": {"id": "d"}}, {"narrator": {"name": "e"}}],
                "search": [{"collection": {"id": "f"}}, {"playlist": {"id": "g"}}, {"history": {"itemID": "h"}}],
                "downloads": [{"localFolder": {"id": "i"}}, {"localItem": {"id": "j"}}, {"downloadQueue": {}}],
                "account": [{"stats": {}}, {"logs": {}}, {"servers": {}}, {"settings": {}}],
                "addPodcast": [{"item": {"id": "k"}}]
              }
            }
            """
        let snapshot = try JSONDecoder().decode(Router.Snapshot.self, from: Data(json.utf8))

        let expected = Router.Snapshot(
            serverID: "server-1", userID: "user-1", selectedTab: .addPodcast, libraryID: "podcasts",
            libraryKind: .podcast, librarySection: .latest,
            paths: [
                .home: [.item(id: "a"), .episode(itemID: "a", episodeID: "b")],
                .library: [.series(id: "c"), .author(id: "d"), .narrator(name: "e")],
                .search: [.collection(id: "f"), .playlist(id: "g"), .history(itemID: "h")],
                .downloads: [.localFolder(id: "i"), .localItem(id: "j"), .downloadQueue],
                .account: [.stats, .logs, .servers, .settings],
                .addPodcast: [.item(id: "k")],
            ],
            isQueueInspectorPresented: true
        )
        #expect(snapshot == expected)
    }

    @Test func unknownTabsAreSkipped() throws {
        let json = """
            {"serverID": "s", "userID": "u", "selectedTab": "home", "isQueueInspectorPresented": false,
             "paths": {"radio": [{"item": {"id": "x"}}], "home": [{"item": {"id": "a"}}]}}
            """
        let snapshot = try JSONDecoder().decode(Router.Snapshot.self, from: Data(json.utf8))
        #expect(snapshot.paths == [.home: [.item(id: "a")]])
    }

    @Test func pathsAreCutAtTheFirstUnknownRoute() throws {
        let json = """
            {"serverID": "s", "userID": "u", "selectedTab": "home", "isQueueInspectorPresented": false,
             "paths": {
               "home": [{"item": {"id": "a"}}, {"chapter": {"id": "x"}}, {"item": {"id": "b"}}],
               "search": [{"future": {}}],
               "account": [{"stats": {}}]
             }}
            """
        let snapshot = try JSONDecoder().decode(Router.Snapshot.self, from: Data(json.utf8))
        #expect(snapshot.paths == [.home: [.item(id: "a")], .account: [.stats]])
    }

    @Test func unknownLibrarySectionFallsBackToTheGridAndKeepsOtherPaths() {
        let json = """
            {"serverID": "s", "userID": "u", "selectedTab": "library", "libraryID": "books",
             "libraryKind": "book", "librarySection": "genres", "isQueueInspectorPresented": false,
             "paths": {
               "library": [{"item": {"id": "from-genres"}}],
               "home": [{"item": {"id": "a"}}],
               "downloads": [{"downloadQueue": {}}],
               "account": [{"stats": {}}]
             }}
            """
        let router = Router(serverID: "s", userID: "u")
        router.restore(from: Data(json.utf8))

        #expect(router.selectedTab == .library)
        #expect(router.libraryID == "books")
        #expect(router.libraryKind == .book)
        #expect(router.librarySection == nil)
        #expect(
            router.paths == [.home: [.item(id: "a")], .downloads: [.downloadQueue], .account: [.stats]]
        )
    }

    @Test func unknownSelectedTabAndLibraryKindFallBack() {
        let json = """
            {"serverID": "s", "userID": "u", "selectedTab": "radio", "libraryID": "music",
             "libraryKind": "music", "isQueueInspectorPresented": true,
             "paths": {"home": [{"item": {"id": "a"}}], "account": [{"stats": {}}]}}
            """
        let router = Router(serverID: "s", userID: "u")
        router.restore(from: Data(json.utf8))

        #expect(router.selectedTab == .home)
        #expect(router.libraryID == "music")
        #expect(router.libraryKind == nil)
        #expect(router.paths == [.home: [.item(id: "a")], .account: [.stats]])
        #expect(router.isQueueInspectorPresented == true)
    }

    @Test func snapshotDataRestores() throws {
        let original = populatedRouter()
        let data = try #require(original.snapshotData)

        let restored = Router(serverID: "server-1", userID: "user-1")
        restored.restore(from: data)

        #expect(restored.snapshot == original.snapshot)
    }

    @Test(arguments: [nil, Data("not json".utf8), Data(#"{"serverID": "s", "userID": "u"}"#.utf8)])
    func unreadableDataStartsFromDefaults(data: Data?) {
        let router = Router(serverID: "s", userID: "u")
        router.selectLibrary(id: "books", kind: .book, supportedSections: AppTab.sections(for: .book))
        router[path: .home] = [.item(id: "li_1")]
        router.isQueueInspectorPresented = true
        router.isFullPlayerPresented = true

        router.restore(from: data)

        #expect(router.snapshot == Router.Snapshot(serverID: "s", userID: "u"))
        #expect(router.isFullPlayerPresented == true)
    }

    @Test func droppedLibrarySectionDropsTheLibraryPath() {
        let router = Router(serverID: "s", userID: "u")
        router.snapshot = Router.Snapshot(
            serverID: "s", userID: "u", selectedTab: .library, libraryID: "podcasts", libraryKind: .podcast,
            librarySection: .series, paths: [.library: [.series(id: "se_1")], .home: [.item(id: "li_1")]]
        )

        #expect(router.librarySection == nil)
        #expect(router[path: .library] == [])
        #expect(router[path: .home] == [.item(id: "li_1")])
    }

    @Test func restoredSectionTabMovesIntoLibraryInCompactWidth() {
        let router = Router(serverID: "s", userID: "u")
        router.snapshot = Router.Snapshot(
            serverID: "s", userID: "u", selectedTab: .series, libraryID: "books", libraryKind: .book,
            paths: [.series: [.series(id: "se_1"), .item(id: "li_1")], .library: [.item(id: "old")]]
        )

        router.normalize(isCompact: true)

        #expect(router.selectedTab == .library)
        #expect(router.librarySection == .series)
        #expect(router[path: .library] == [.series(id: "se_1"), .item(id: "li_1")])
        #expect(router[path: .series] == [])
    }
}
