import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

private let key = LibraryConnectionKey(connectionID: identityA.connectionID, userID: identityA.userID)

@MainActor
private func loadedStore(_ settings: AppSettings, libraries: [Library]) async -> LibraryStore {
    let store = LibraryStore(settings: settings)
    var service = FakeLibraryService()
    service.librariesHandler = { libraries }
    await store.connect(client: service, connectionKey: key, defaultLibraryID: nil)
    return store
}

@MainActor
@Suite struct LibraryCommandTests {
    @Test func noItemsWithoutAFocusedSceneOrAStore() async throws {
        try await withLibrarySettings { settings in
            let store = await loadedStore(settings, libraries: [makeLibrary("books")])
            #expect(LibraryCommand.items(router: nil, store: store).isEmpty)
            #expect(LibraryCommand.items(router: Router(identity: identityA), store: nil).isEmpty)
            // Nothing to run it in; it must not trap.
            LibraryCommand.select("books", router: nil, store: store)
            #expect(store.lastLibraryID == nil)
        }
    }

    @Test func noItemsForAStoreOfAnotherAccount() async throws {
        try await withLibrarySettings { settings in
            let store = await loadedStore(settings, libraries: [makeLibrary("books")])
            let router = Router(identity: identityB)
            #expect(LibraryCommand.items(router: router, store: store).isEmpty)

            LibraryCommand.select("books", router: router, store: store)
            #expect(router.libraryID == nil)
            #expect(store.lastLibraryID == nil)
        }
    }

    @Test func itemsFollowServerOrderAndTheFirstNineTakeShortcuts() async throws {
        try await withLibrarySettings { settings in
            let libraries = (1...11).map { makeLibrary("lib\($0)", name: "Library \($0)") }
            let store = await loadedStore(settings, libraries: libraries)
            let items = LibraryCommand.items(router: Router(identity: identityA), store: store)

            #expect(items.map(\.id) == libraries.map(\.id))
            #expect(items.map(\.name) == libraries.map(\.name))
            #expect(items.map(\.shortcutDigit) == Array(1...9) + [nil, nil])
        }
    }

    @Test func currentLibraryIsMarkedAndSelectSwitchesAsThePickerDoes() async throws {
        try await withLibrarySettings { settings in
            let store = await loadedStore(
                settings, libraries: [makeLibrary("books"), makeLibrary("pods", mediaType: .podcast)])
            let router = Router(identity: identityA)
            SceneLibrarySelection.reconcile(router, store: store)
            #expect(LibraryCommand.items(router: router, store: store).map(\.isCurrent) == [true, false])

            LibraryCommand.select("pods", router: router, store: store)
            #expect(router.libraryID == "pods")
            #expect(router.libraryKind == .podcast)
            #expect(store.lastLibraryID == "pods")
            #expect(LibraryCommand.items(router: router, store: store).map(\.isCurrent) == [false, true])

            // A library that's gone is ignored.
            LibraryCommand.select("unknown", router: router, store: store)
            #expect(router.libraryID == "pods")
        }
    }
}
