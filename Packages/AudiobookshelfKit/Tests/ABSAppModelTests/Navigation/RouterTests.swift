import Foundation
import Testing

@testable import ABSAppModel

private let bookSections = AppTab.sections(for: .book)
private let podcastSections = AppTab.sections(for: .podcast)

@MainActor
private func routerInBookLibrary() -> Router {
    let router = Router(serverID: "server-1", userID: "user-1")
    router.selectLibrary(id: "books", mediaType: .book, supportedSections: bookSections)
    return router
}

@MainActor
@Suite struct RouterTests {
    // MARK: Paths

    @Test func pathSubscriptDefaultsToEmptyAndDropsEmptyPaths() {
        let router = Router()
        #expect(router[path: .home] == [])

        router[path: .home] = [.item(id: "li_1")]
        #expect(router.paths == [.home: [.item(id: "li_1")]])

        router[path: .home] = []
        #expect(router.paths.isEmpty)
    }

    // MARK: Sections

    @Test func sectionsMatchTheLegacyNavBar() {
        #expect(AppTab.sections(for: .book) == [.series, .collections, .authors, .playlists])
        #expect(AppTab.sections(for: .podcast) == [.latest, .addPodcast, .playlists])
        #expect(AppTab.sections(for: nil) == [])
        #expect(AppTab.sections(for: .podcast, canAddPodcast: false, hasPlaylists: true) == [.latest, .playlists])
        #expect(
            AppTab.sections(for: .book, canAddPodcast: true, hasPlaylists: false) == [.series, .collections, .authors])
        #expect(LibraryKind(.podcast) == .podcast)
        #expect(LibraryKind(.unknown("music")) == nil)
    }

    // MARK: Compact width

    @Test func compactWidthMovesTheSelectedSectionIntoLibrary() {
        let router = routerInBookLibrary()
        router.selectedTab = .series
        router[path: .series] = [.series(id: "se_1"), .item(id: "li_1")]

        router.normalize(isCompact: true)

        #expect(router.selectedTab == .library)
        #expect(router.librarySection == .series)
        #expect(router[path: .library] == [.series(id: "se_1"), .item(id: "li_1")])
        #expect(router[path: .series] == [])
    }

    @Test func compactTransferReplacesTheHiddenLibraryPath() {
        let router = routerInBookLibrary()
        router[path: .library] = [.item(id: "old")]
        router.selectedTab = .authors
        router[path: .authors] = [.author(id: "au_1")]

        router.normalize(isCompact: true)

        #expect(router[path: .library] == [.author(id: "au_1")])
        #expect(router.librarySection == .authors)
    }

    @Test func compactTransferOfASectionAtItsRootClearsLibrary() {
        let router = routerInBookLibrary()
        router[path: .library] = [.item(id: "old")]
        router.selectedTab = .collections

        router.normalize(isCompact: true)

        #expect(router[path: .library] == [])
        #expect(router.librarySection == .collections)
    }

    @Test func normalizeLeavesOtherStatesAlone() {
        let router = routerInBookLibrary()
        router.selectedTab = .series
        router[path: .series] = [.series(id: "se_1")]
        router.normalize(isCompact: false)
        #expect(router.selectedTab == .series)
        #expect(router[path: .series] == [.series(id: "se_1")])

        router.selectedTab = .downloads
        router[path: .downloads] = [.downloadQueue]
        router.normalize(isCompact: true)
        #expect(router.selectedTab == .downloads)
        #expect(router[path: .downloads] == [.downloadQueue])
        #expect(router.librarySection == nil)
    }

    @Test func returningToRegularWidthMovesNothingBack() {
        let router = routerInBookLibrary()
        router.selectedTab = .series
        router[path: .series] = [.item(id: "li_1")]
        router.normalize(isCompact: true)

        router.normalize(isCompact: false)

        #expect(router.selectedTab == .library)
        #expect(router.librarySection == .series)
        #expect(router[path: .library] == [.item(id: "li_1")])
        #expect(router[path: .series] == [])
    }

    // MARK: Library switching

    @Test func switchingLibrariesResetsOnlyLibraryScopedPaths() {
        let router = routerInBookLibrary()
        for tab in AppTab.allCases {
            router[path: tab] = [.item(id: tab.rawValue)]
        }

        router.selectLibrary(id: "books-2", mediaType: .book, supportedSections: bookSections)

        #expect(router.libraryID == "books-2")
        for tab in AppTab.allCases {
            let expected: [Route] = tab.isLibraryScoped ? [] : [.item(id: tab.rawValue)]
            #expect(router[path: tab] == expected, "\(tab)")
        }
        #expect(router[path: .downloads] == [.item(id: "downloads")])
        #expect(router[path: .account] == [.item(id: "account")])
        #expect(router[path: .search] == [])
    }

    @Test func reselectingTheSameLibraryKeepsPaths() {
        let router = routerInBookLibrary()
        router[path: .home] = [.item(id: "li_1")]

        router.selectLibrary(id: "books", mediaType: .book, supportedSections: bookSections)

        #expect(router[path: .home] == [.item(id: "li_1")])
    }

    @Test func switchingToAPodcastLibraryRepairsBookSections() {
        let router = routerInBookLibrary()
        router.selectedTab = .authors
        router.librarySection = .series

        router.selectLibrary(id: "podcasts", mediaType: .podcast, supportedSections: podcastSections)

        #expect(router.selectedTab == .library)
        #expect(router.librarySection == nil)
        #expect(router.libraryKind == .podcast)
    }

    @Test func switchingToABookLibraryRepairsPodcastSections() {
        let router = Router()
        router.selectLibrary(id: "podcasts", mediaType: .podcast, supportedSections: podcastSections)
        router.selectedTab = .latest
        router.librarySection = .addPodcast

        router.selectLibrary(id: "books", mediaType: .book, supportedSections: bookSections)

        #expect(router.selectedTab == .library)
        #expect(router.librarySection == nil)
    }

    @Test func playlistsSurviveABookToPodcastSwitch() {
        let router = routerInBookLibrary()
        router.selectedTab = .playlists
        router.librarySection = .playlists

        router.selectLibrary(id: "podcasts", mediaType: .podcast, supportedSections: podcastSections)

        #expect(router.selectedTab == .playlists)
        #expect(router.librarySection == .playlists)
    }

    @Test func sharedTabsSurviveALibrarySwitch() {
        for tab in [AppTab.home, .library, .search, .downloads, .account] {
            let router = routerInBookLibrary()
            router.selectedTab = tab
            router.selectLibrary(id: "podcasts", mediaType: .podcast, supportedSections: podcastSections)
            #expect(router.selectedTab == tab)
        }
    }

    @Test func supportedSectionsAlsoApplyPermissions() {
        let router = Router()
        let all = AppTab.sections(for: .podcast, canAddPodcast: true, hasPlaylists: true)
        router.selectLibrary(id: "podcasts", mediaType: .podcast, supportedSections: all)
        router.selectedTab = .addPodcast
        router.librarySection = .playlists

        let limited = AppTab.sections(for: .podcast, canAddPodcast: false, hasPlaylists: false)
        router.selectLibrary(id: "podcasts", mediaType: .podcast, supportedSections: limited)

        #expect(router.selectedTab == .library)
        #expect(router.librarySection == nil)
    }

    // MARK: Identity

    @Test func identityChangeResetsEverything() {
        let router = routerInBookLibrary()
        router.selectedTab = .account
        router.librarySection = .series
        router[path: .account] = [.servers]
        router[path: .downloads] = [.downloadQueue]
        router.isFullPlayerPresented = true
        router.isQueueInspectorPresented = true

        router.resetForIdentityChange(serverID: "server-2", userID: "user-2")

        #expect(router.serverID == "server-2")
        #expect(router.userID == "user-2")
        #expect(router.selectedTab == .home)
        #expect(router.libraryID == nil)
        #expect(router.libraryKind == nil)
        #expect(router.librarySection == nil)
        #expect(router.paths.isEmpty)
        #expect(router.isFullPlayerPresented == false)
        #expect(router.isQueueInspectorPresented == false)
    }

    // MARK: Presentation

    @Test func presentationFlagsArePerScene() {
        let first = routerInBookLibrary()
        let second = routerInBookLibrary()

        first.isFullPlayerPresented = true
        second.isQueueInspectorPresented = true

        #expect(first.isQueueInspectorPresented == false)
        #expect(second.isFullPlayerPresented == false)
    }
}
