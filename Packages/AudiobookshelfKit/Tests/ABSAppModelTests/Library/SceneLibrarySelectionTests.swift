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

    /// A user with no libraries: loading finishes without a library to show, and a library
    /// link has nothing to open.
    @Test func loadedWithoutLibraries() async throws {
        try await withLibrarySettings { settings in
            let store = await loadedStore(settings, libraries: [])
            #expect(store.hasLoaded)
            let router = Router(identity: identityA)
            router.requestLibrary(id: "books")

            SceneLibrarySelection.reconcile(router, store: store)

            #expect(router.libraryID == nil)
            #expect(router.pendingLibraryID == nil)
            SceneLibrarySelection.select("books", router: router, store: store)
            #expect(router.libraryID == nil)
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
}
