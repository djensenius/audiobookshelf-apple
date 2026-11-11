import Foundation
import Testing

@testable import ABSAppModel

/// The navigation seam (#223): the library filter route and the sections the sidebar shows.
@MainActor
@Suite struct NavigationSeamTests {
    // MARK: Library filter route

    /// Pins the stored wire format of the route, which scene snapshots keep.
    @Test(arguments: LibraryFilterKind.allCases)
    func libraryFilterRouteRoundTrips(kind: LibraryFilterKind) throws {
        let route = Route.libraryFilter(kind: kind, value: "Sci Fi/Fantasy")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(route), as: UTF8.self)
        #expect(json == #"{"libraryFilter":{"kind":"\#(kind.rawValue)","value":"Sci Fi\/Fantasy"}}"#)
        #expect(try JSONDecoder().decode(Route.self, from: Data(json.utf8)) == route)
    }

    @Test func libraryFilterKindsAreServerFilterGroups() {
        for kind in LibraryFilterKind.allCases {
            #expect(LibraryFilterGroup(rawValue: kind.rawValue) != nil)
        }
    }

    @Test func libraryFilterRouteSurvivesASnapshotAndCompactWidth() throws {
        let router = Router(serverID: "s", userID: "u")
        router.selectLibrary(id: "books", kind: .book, supportedSections: AppTab.sections(for: .book))
        router.selectedTab = .authors
        router[path: .authors] = [.item(id: "li_1"), .libraryFilter(kind: .narrators, value: "Ned")]

        let restored = Router(serverID: "s", userID: "u")
        restored.restore(from: router.snapshotData)
        restored.normalize(isCompact: true)

        #expect(restored.selectedTab == .library)
        #expect(restored.librarySection == .authors)
        #expect(restored[path: .library] == [.item(id: "li_1"), .libraryFilter(kind: .narrators, value: "Ned")])
    }

    /// A snapshot saved before the route existed still restores as it was.
    @Test func snapshotFromBeforeTheRouteDecodes() throws {
        let json = """
            {"serverID": "s", "userID": "u", "selectedTab": "library", "libraryID": "books",
             "libraryKind": "book", "isQueueInspectorPresented": false,
             "paths": {"library": [{"item": {"id": "a"}}, {"narrator": {"name": "Ned"}}]}}
            """
        let snapshot = try JSONDecoder().decode(Router.Snapshot.self, from: Data(json.utf8))
        #expect(snapshot.paths == [.library: [.item(id: "a"), .narrator(name: "Ned")]])
    }

    /// A filter kind this build doesn't know cuts the path there, like any unknown route.
    @Test func unknownFilterKindCutsThePath() throws {
        let json = """
            {"serverID": "s", "userID": "u", "selectedTab": "home", "isQueueInspectorPresented": false,
             "paths": {"home": [{"item": {"id": "a"}}, {"libraryFilter": {"kind": "moods", "value": "x"}},
                                {"item": {"id": "b"}}]}}
            """
        let snapshot = try JSONDecoder().decode(Router.Snapshot.self, from: Data(json.utf8))
        #expect(snapshot.paths == [.home: [.item(id: "a")]])
    }

    // MARK: Section filtering

    @Test func bookLibraryShowsSeriesCollectionsAndAuthors() {
        let router = Router()
        let sections = AppTab.sections(for: .book, canAddPodcast: true, hasPlaylists: false)
        router.selectLibrary(id: "books", kind: .book, supportedSections: sections)
        #expect(router.visibleSections == [.series, .collections, .authors])
    }

    @Test func podcastLibraryShowsLatestAndAddPodcastForAdmins() {
        let router = Router()
        let admin = AppTab.sections(for: .podcast, canAddPodcast: true, hasPlaylists: false)
        router.selectLibrary(id: "podcasts", kind: .podcast, supportedSections: admin)
        #expect(router.visibleSections == [.latest, .addPodcast])

        let user = AppTab.sections(for: .podcast, canAddPodcast: false, hasPlaylists: false)
        router.selectLibrary(id: "podcasts", kind: .podcast, supportedSections: user)
        #expect(router.visibleSections == [.latest])
    }

    @Test(arguments: [LibraryKind.book, .podcast])
    func playlistsShowOnlyWhenTheUserHasAny(kind: LibraryKind) {
        let router = Router()
        let with = AppTab.sections(for: kind, canAddPodcast: false, hasPlaylists: true)
        router.selectLibrary(id: "lib", kind: kind, supportedSections: with)
        #expect(router.visibleSections.contains(.playlists))

        let without = AppTab.sections(for: kind, canAddPodcast: false, hasPlaylists: false)
        router.selectLibrary(id: "lib", kind: kind, supportedSections: without)
        #expect(!router.visibleSections.contains(.playlists))
    }

    @Test func noLibraryShowsNoSections() {
        let router = Router(serverID: "s", userID: "u")
        #expect(router.visibleSections == [])

        router.selectLibrary(id: "books", kind: .book, supportedSections: AppTab.sections(for: .book))
        router.resetForIdentityChange(serverID: "s", userID: "other")
        #expect(router.visibleSections == [])
    }

    /// A restored scene shows every section of its library's kind until the scene confirms the
    /// library with the user's permissions and playlists.
    @Test func restoredSceneShowsTheKindsSectionsUntilConfirmed() {
        let router = Router(serverID: "s", userID: "u")
        router.selectLibrary(id: "pods", kind: .podcast, supportedSections: [.latest])
        let restored = Router(serverID: "s", userID: "u")
        restored.snapshot = router.snapshot
        #expect(restored.visibleSections == [.playlists, .latest, .addPodcast])

        restored.selectLibrary(id: "pods", kind: .podcast, supportedSections: [.latest])
        #expect(restored.visibleSections == [.latest])
    }
}
