import Foundation
import Testing

@testable import ABSAppModel

@MainActor
private func routerInBookLibrary() -> Router {
    let router = Router(serverID: "server-1", userID: "user-1")
    router.selectLibrary(id: "books", kind: .book, supportedSections: AppTab.sections(for: .book))
    return router
}

@MainActor
@Suite struct RouterCommandsTests {
    // MARK: Enablement

    @Test(arguments: GoCommand.allCases)
    func noCommandIsEnabledWithoutAFocusedScene(command: GoCommand) {
        #expect(!command.isEnabled(in: nil))
        // Nothing to run it in; it must not trap.
        command.perform(in: nil)
    }

    @Test(arguments: GoCommand.tabs)
    func tabCommandsAreEnabledInAnyScene(command: GoCommand) throws {
        let router = routerInBookLibrary()
        #expect(command.isEnabled(in: router))

        // Also the selected tab, and before the scene has a library.
        router.selectedTab = try #require(command.tab)
        #expect(command.isEnabled(in: router))
        #expect(command.isEnabled(in: Router()))
    }

    @Test func backIsEnabledOnlyAboveTheSelectedTabsRoot() {
        let router = routerInBookLibrary()
        router.selectedTab = .home
        #expect(!router.canGoBack)
        #expect(!GoCommand.back.isEnabled(in: router))

        // Another tab's path doesn't count.
        router[path: .library] = [.item(id: "li_1")]
        #expect(!GoCommand.back.isEnabled(in: router))

        router[path: .home] = [.stats]
        #expect(router.canGoBack)
        #expect(GoCommand.back.isEnabled(in: router))

        router.selectedTab = .account
        #expect(!GoCommand.back.isEnabled(in: router))
    }

    // MARK: Menu

    @Test func menuListsTheTabsEveryLibraryHasThenBack() {
        #expect(GoCommand.tabs.map(\.tab) == [.home, .library, .search, .downloads, .account])
        #expect(GoCommand.allCases == GoCommand.tabs + [.back])
        #expect(GoCommand.back.tab == nil)
        #expect(GoCommand.tabs.allSatisfy { $0.tab?.isSection == false })
    }

    // MARK: Selecting a tab

    @Test func tabCommandSelectsItsTabKeepingPathsAndDismissingTheFullPlayer() {
        let router = routerInBookLibrary()
        router[path: .library] = [.item(id: "li_1")]
        router[path: .downloads] = [.downloadQueue]
        router.isFullPlayerPresented = true
        router.isQueueInspectorPresented = true

        GoCommand.library.perform(in: router)
        #expect(router.selectedTab == .library)
        #expect(router[path: .library] == [.item(id: "li_1")])
        #expect(!router.isFullPlayerPresented)
        #expect(router.isQueueInspectorPresented)

        GoCommand.downloads.perform(in: router)
        #expect(router.selectedTab == .downloads)
        #expect(router[path: .downloads] == [.downloadQueue])
        #expect(router[path: .library] == [.item(id: "li_1")])
        #expect(router.libraryID == "books")
    }

    @Test func libraryCommandKeepsTheCompactSection() {
        let router = routerInBookLibrary()
        router.selectedTab = .series
        router.normalize(isCompact: true)
        router.selectedTab = .home

        GoCommand.library.perform(in: router)
        #expect(router.selectedTab == .library)
        #expect(router.librarySection == .series)
    }

    @Test func selectingASectionIsIgnored() {
        let router = routerInBookLibrary()
        router.selectedTab = .home
        router.isFullPlayerPresented = true

        router.select(tab: .series)
        #expect(router.selectedTab == .home)
        #expect(router.isFullPlayerPresented)
    }

    // MARK: Back

    @Test func backPopsOnlyTheSelectedTabsTopScreen() {
        let router = routerInBookLibrary()
        router.selectedTab = .library
        router[path: .library] = [.series(id: "se_1"), .item(id: "li_1")]
        router[path: .home] = [.stats]
        router.isFullPlayerPresented = true

        GoCommand.back.perform(in: router)
        #expect(router[path: .library] == [.series(id: "se_1")])
        #expect(router[path: .home] == [.stats])
        #expect(router.selectedTab == .library)
        #expect(!router.isFullPlayerPresented)

        GoCommand.back.perform(in: router)
        #expect(router[path: .library].isEmpty)
        #expect(router.paths[.library] == nil)
        #expect(!GoCommand.back.isEnabled(in: router))
    }

    @Test func backAtTheRootChangesNothing() {
        let router = routerInBookLibrary()
        router.selectedTab = .account
        router[path: .home] = [.stats]
        router.isFullPlayerPresented = true

        GoCommand.back.perform(in: router)
        #expect(router.selectedTab == .account)
        #expect(router[path: .home] == [.stats])
        #expect(router.isFullPlayerPresented)
    }

    @Test func backFromACompactSectionStaysInTheSection() {
        let router = routerInBookLibrary()
        router.selectedTab = .series
        router[path: .series] = [.series(id: "se_1")]
        router.normalize(isCompact: true)

        router.goBack()
        #expect(router.selectedTab == .library)
        #expect(router.librarySection == .series)
        #expect(router[path: .library].isEmpty)
    }

    @Test func backFromTheLinkedScreenDropsThePendingPlayLink() {
        let router = routerInBookLibrary()
        router.open(DeepLink(.play(PlayLink(itemID: "li_1"))))
        #expect(router.pendingPlayLink != nil)

        router.goBack()
        #expect(router[path: .library].isEmpty)
        #expect(router.pendingPlayLink == nil)
    }
}
