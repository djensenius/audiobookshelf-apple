import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

private let key = LibraryConnectionKey(connectionID: identityA.connectionID, userID: identityA.userID)

@MainActor
private func loadedStore(_ settings: AppSettings, libraries: [Library], defaultLibraryID: String? = nil) async
    -> LibraryStore
{
    let store = LibraryStore(settings: settings)
    var service = FakeLibraryService()
    service.librariesHandler = { libraries }
    await store.connect(client: service, connectionKey: key, defaultLibraryID: defaultLibraryID)
    return store
}

private let books = makeLibrary("books")
private let pods = makeLibrary("pods", mediaType: .podcast)

@MainActor
@Suite struct SceneLibrarySelectionTests {
    @Test func startsUncheckedBeforeTheLibrariesLoad() async throws {
        try await withLibrarySettings { settings in
            settings.setLastLibraryID("gone", serverID: key.serverID, userID: key.userID)
            let store = LibraryStore(settings: settings)
            store.attach(client: nil, connectionKey: key)
            let router = Router(identity: identityA)

            SceneLibrarySelection.reconcile(router, store: store)

            #expect(router.libraryID == "gone")
            #expect(router.libraryKind == nil)
            #expect(router.supportedSections == Set(AppTab.sections))
        }
    }

    @Test func revalidatesOnceLoaded() async throws {
        try await withLibrarySettings { settings in
            settings.setLastLibraryID("gone", serverID: key.serverID, userID: key.userID)
            let store = await loadedStore(settings, libraries: [books, pods], defaultLibraryID: "pods")
            let router = Router(identity: identityA)
            router.restoreLibrary(id: "gone", kind: .book)

            SceneLibrarySelection.reconcile(router, store: store)

            // The saved library is gone, so the default one, with its kind and sections.
            #expect(router.libraryID == "pods")
            #expect(router.libraryKind == .podcast)
            #expect(router.supportedSections == AppTab.sections(for: .podcast))
            // Only a user's pick is saved.
            #expect(store.lastLibraryID == "gone")
        }
    }

    /// A deep link opened while the scene showed its unchecked guess survives the fallback
    /// when the libraries load and the guess is gone.
    @Test func fallbackFromAnUncheckedGuessKeepsADeepLink() async throws {
        try await withLibrarySettings { settings in
            settings.setLastLibraryID("gone", serverID: key.serverID, userID: key.userID)
            let store = LibraryStore(settings: settings)
            var service = FakeLibraryService()
            service.librariesHandler = { [books, pods] }
            store.attach(client: service, connectionKey: key, defaultLibraryID: "pods")
            let router = Router(identity: identityA)
            SceneLibrarySelection.reconcile(router, store: store)
            #expect(router.libraryID == "gone")
            router.open(DeepLink(.item(id: "li_1", episodeID: nil)))

            await store.refresh()
            SceneLibrarySelection.reconcile(router, store: store)

            #expect(router.libraryID == "pods")
            #expect(router.libraryKind == .podcast)
            #expect(router.supportedSections == AppTab.sections(for: .podcast))
            #expect(router.selectedTab == .library)
            #expect(router[path: .library] == [.item(id: "li_1")])
        }
    }

    /// A new scene of a user with no libraries shows no sections once they load, not every
    /// section as before a library is chosen.
    @Test func newSceneWithoutLibrariesShowsNoSections() async throws {
        try await withLibrarySettings { settings in
            let store = await loadedStore(settings, libraries: [])
            let router = Router(identity: identityA)
            #expect(router.visibleSections == AppTab.sections)

            SceneLibrarySelection.reconcile(router, store: store)

            #expect(router.libraryID == nil)
            #expect(router.visibleSections.isEmpty)
        }
    }

    /// A restored library, kind included, isn't checked yet: when it's gone, the fallback keeps
    /// the launch link opened over it. Once a library is checked, its removal resets the paths.
    @Test func fallbackFromARestoredLibraryKeepsALaunchLink() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            let libraries = Locked([books])
            var service = FakeLibraryService()
            service.librariesHandler = { libraries.value }
            store.attach(client: service, connectionKey: key, defaultLibraryID: "books")
            let router = Router(identity: identityA)
            router.restoreLibrary(id: "gone", kind: .podcast)
            let play = PlayLink(itemID: "li_1")
            router.open(DeepLink(.play(play)))
            let opened = router[path: .library]
            #expect(!opened.isEmpty)

            await store.refresh()
            SceneLibrarySelection.reconcile(router, store: store)

            #expect(router.libraryID == "books")
            #expect(router.libraryKind == .book)
            #expect(router[path: .library] == opened)
            #expect(router.pendingPlayLink == play)

            // Removed after it was checked: its paths go.
            libraries.value = [pods]
            await store.refresh()
            SceneLibrarySelection.reconcile(router, store: store)
            #expect(router.libraryID == "pods")
            #expect(router[path: .library].isEmpty)
        }
    }

    /// A compact scene restored in a book library's Series section: when that library is gone
    /// and a podcast library replaces it, Series falls back to the default grid, but the launch
    /// link's screen, pushed onto the Library path, stays with its pending play link.
    @Test func sectionFallbackFromARestoredLibraryKeepsALaunchLink() async throws {
        try await withLibrarySettings { settings in
            let store = await loadedStore(settings, libraries: [pods], defaultLibraryID: "pods")
            let router = Router(identity: identityA)
            router.restoreLibrary(id: "gone", kind: .book)
            router.librarySection = .series
            router[path: .library] = [.series(id: "s1")]
            let play = PlayLink(itemID: "li_1")
            router.open(DeepLink(.play(play)))
            let opened = router[path: .library]
            #expect(opened.last == .item(id: "li_1"))

            SceneLibrarySelection.reconcile(router, store: store)

            #expect(router.libraryID == "pods")
            #expect(router.librarySection == nil)
            #expect(router.selectedTab == .library)
            #expect(router[path: .library] == opened)
            #expect(router.pendingPlayLink == play)
        }
    }

    /// A scene guessed into a library before it loaded, with a launch link opened from Series:
    /// the guess turns out to be a podcast library, which has no Series, so Series falls back
    /// to the default grid, but the launch link's screen and pending play link stay.
    @Test func sectionFallbackInAnUncheckedValidLibraryKeepsALaunchLink() async throws {
        try await withLibrarySettings { settings in
            let store = await loadedStore(settings, libraries: [pods], defaultLibraryID: "pods")
            let router = Router(identity: identityA)
            router.restoreLibrary(id: "pods", kind: nil)
            router.librarySection = .series
            router[path: .library] = [.series(id: "s1")]
            let play = PlayLink(itemID: "li_1")
            router.open(DeepLink(.play(play)))
            let opened = router[path: .library]
            #expect(opened.last == .item(id: "li_1"))

            SceneLibrarySelection.reconcile(router, store: store)

            #expect(router.libraryID == "pods")
            #expect(router.libraryKind == .podcast)
            #expect(router.isLibraryChecked)
            #expect(router.librarySection == nil)
            #expect(router.selectedTab == .library)
            #expect(router[path: .library] == opened)
            #expect(router.pendingPlayLink == play)
        }
    }

    /// A user with no libraries: a saved or previous library is dropped with its library-scoped
    /// paths, other tabs are kept, and a library link has nothing to open.
    @Test func loadedWithoutLibraries() async throws {
        try await withLibrarySettings { settings in
            settings.setLastLibraryID("gone", serverID: key.serverID, userID: key.userID)
            let store = await loadedStore(settings, libraries: [])
            #expect(store.hasLoaded)
            let router = Router(identity: identityA)
            router.restoreLibrary(id: "gone", kind: .book)
            router.selectedTab = .series
            router[path: .home] = [.item(id: "li_1")]
            router[path: .series] = [.series(id: "se_1")]
            router[path: .downloads] = [.item(id: "li_2")]
            router.requestLibrary(id: "books")

            SceneLibrarySelection.reconcile(router, store: store)

            #expect(router.libraryID == nil)
            #expect(router.libraryKind == nil)
            #expect(router.supportedSections.isEmpty)
            #expect(router.visibleSections.isEmpty)
            #expect(router.pendingLibraryID == nil)
            #expect(router.selectedTab == .library)
            #expect(router[path: .home].isEmpty)
            #expect(router[path: .series].isEmpty)
            #expect(router[path: .downloads] == [.item(id: "li_2")])
            SceneLibrarySelection.select("books", router: router, store: store)
            #expect(router.libraryID == nil)
        }
    }

    /// A link to the library already shown is resolved, so it can't pull the scene back after
    /// the user picks another library.
    @Test func linkToTheShownLibraryDoesNotOverrideALaterPick() async throws {
        try await withLibrarySettings { settings in
            let store = await loadedStore(settings, libraries: [books, pods])
            let router = Router(identity: identityA)
            SceneLibrarySelection.select("pods", router: router, store: store)
            router.requestLibrary(id: "pods")
            SceneLibrarySelection.reconcile(router, store: store)
            #expect(router.pendingLibraryID == nil)

            SceneLibrarySelection.select("books", router: router, store: store)
            SceneLibrarySelection.reconcile(router, store: store)
            #expect(router.libraryID == "books")
        }
    }

    @Test func keepsAValidLibraryAndConfirmsItsKind() async throws {
        try await withLibrarySettings { settings in
            let store = await loadedStore(settings, libraries: [books, pods])
            let router = Router(identity: identityA)
            router.restoreLibrary(id: "pods", kind: nil)
            router.selectedTab = .latest

            SceneLibrarySelection.reconcile(router, store: store)

            #expect(router.libraryID == "pods")
            #expect(router.libraryKind == .podcast)
            #expect(router.selectedTab == .latest)
        }
    }

    @Test func selectShowsAndSavesTheLibrary() async throws {
        try await withLibrarySettings { settings in
            let store = await loadedStore(settings, libraries: [books, pods])
            let router = Router(identity: identityA)
            SceneLibrarySelection.reconcile(router, store: store)
            #expect(router.libraryID == "books")

            SceneLibrarySelection.select("pods", router: router, store: store)
            #expect(router.libraryID == "pods")
            #expect(store.lastLibraryID == "pods")

            SceneLibrarySelection.select("unknown", router: router, store: store)
            #expect(router.libraryID == "pods")
            #expect(store.lastLibraryID == "pods")
        }
    }

    @Test func opensAPendingLibraryOrDropsAnUnknownOne() async throws {
        try await withLibrarySettings { settings in
            let store = await loadedStore(settings, libraries: [books, pods])
            let router = Router(identity: identityA)
            router.requestLibrary(id: "pods")
            SceneLibrarySelection.reconcile(router, store: store)
            #expect(router.libraryID == "pods")
            #expect(router.pendingLibraryID == nil)

            router.requestLibrary(id: "unknown")
            SceneLibrarySelection.reconcile(router, store: store)
            #expect(router.libraryID == "pods")
            #expect(router.pendingLibraryID == nil)
        }
    }

    @Test func ignoresAStoreOfAnotherAccount() async throws {
        try await withLibrarySettings { settings in
            let store = await loadedStore(settings, libraries: [books])
            let router = Router(identity: identityB)

            SceneLibrarySelection.reconcile(router, store: store)
            SceneLibrarySelection.select("books", router: router, store: store)

            #expect(router.libraryID == nil)
            #expect(store.lastLibraryID == nil)
            #expect(!SceneLibrarySelection.isServing(router: router, store: store))
            #expect(SceneLibrarySelection.isServing(router: Router(identity: identityA), store: store))
        }
    }

    /// Add podcast, as legacy `BookshelfNavBar.vue`: hidden from users known not to be allowed,
    /// kept for those who are and while the user is unknown (offline or authorizing).
    @Test(arguments: [(true, true), (false, false), (nil, true)] as [(Bool?, Bool)])
    func addPodcastFollowsThePermission(canAddPodcast: Bool?, shown: Bool) async throws {
        try await withLibrarySettings { settings in
            let store = await loadedStore(settings, libraries: [books, pods], defaultLibraryID: "pods")
            let router = Router(identity: identityA)

            SceneLibrarySelection.reconcile(router, store: store, canAddPodcast: canAddPodcast)
            #expect(router.libraryID == "pods")
            #expect(router.visibleSections.contains(.addPodcast) == shown)
            #expect(router.visibleSections.contains(.latest))

            // A pick and an unchecked guess's check apply it too.
            SceneLibrarySelection.select("books", router: router, store: store, canAddPodcast: canAddPodcast)
            SceneLibrarySelection.select("pods", router: router, store: store, canAddPodcast: canAddPodcast)
            #expect(router.visibleSections.contains(.addPodcast) == shown)
            let guessed = Router(identity: identityA)
            guessed.restoreLibrary(id: "pods", kind: nil)
            SceneLibrarySelection.reconcile(guessed, store: store, canAddPodcast: canAddPodcast)
            #expect(guessed.isLibraryChecked && guessed.visibleSections.contains(.addPodcast) == shown)
        }
    }

    /// Losing the permission (a refreshed user, another account's role) while on Add podcast
    /// falls back to Library and drops the section's screens.
    @Test func losingThePermissionLeavesAddPodcast() async throws {
        try await withLibrarySettings { settings in
            let store = await loadedStore(settings, libraries: [pods], defaultLibraryID: "pods")
            let router = Router(identity: identityA)
            SceneLibrarySelection.reconcile(router, store: store, canAddPodcast: true)
            router.selectedTab = .addPodcast
            router.librarySection = .addPodcast
            router[path: .addPodcast] = [.item(id: "li_new")]
            #expect(
                SceneLibrarySelection.trigger(router, store: store, canAddPodcast: true)
                    != SceneLibrarySelection.trigger(router, store: store, canAddPodcast: false))

            SceneLibrarySelection.reconcile(router, store: store, canAddPodcast: false)

            #expect(router.selectedTab == .library)
            #expect(router.librarySection == nil)
            #expect(router[path: .addPodcast].isEmpty)
            #expect(!router.visibleSections.contains(.addPodcast))
        }
    }
}
