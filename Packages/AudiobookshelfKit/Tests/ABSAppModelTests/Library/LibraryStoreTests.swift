import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

private let serverA = LibraryConnectionKey(
    connectionID: UUID(uuidString: "00000000-0000-0000-0000-00000000000A") ?? UUID(), userID: "user-1")
private let serverB = LibraryConnectionKey(
    connectionID: UUID(uuidString: "00000000-0000-0000-0000-00000000000B") ?? UUID(), userID: "user-1")

private func service(_ libraries: [Library]) -> FakeLibraryService {
    var service = FakeLibraryService()
    service.librariesHandler = { libraries }
    service.libraryHandler = { id in
        LibraryWithFilterData(
            library: Library(id: id, name: "\(id) (detailed)", mediaType: .podcast),
            filterData: LibraryFilterData(genres: ["Genre of \(id)"]))
    }
    return service
}

@MainActor
@Suite struct LibraryStoreTests {
    @Test func connectLoadsTheLibraries() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: service([makeLibrary("books"), makeLibrary("pods")]), connectionKey: serverA)

            #expect(store.connectionKey == serverA)
            #expect(store.libraries.map(\.id) == ["books", "pods"])
            #expect(store.mediaType(libraryID: "books") == .book)
            #expect(store.initialLibraryID == "books")
            #expect(!store.isLoading)
        }
    }

    @Test func lastLibraryIsSavedPerServerAndUser() async throws {
        try await withLibrarySettings { settings in
            let libraries = [makeLibrary("books"), makeLibrary("pods")]
            let store = LibraryStore(settings: settings)
            await store.connect(client: service(libraries), connectionKey: serverA)

            store.saveLastLibraryID("pods")
            #expect(store.lastLibraryID == "pods")
            #expect(store.initialLibraryID == "pods")
            #expect(settings.lastLibraryID(serverID: serverA.connectionID.uuidString, userID: "user-1") == "pods")
            #expect(
                settings.lastLibraryIDs
                    == [AppSettings.accountKey(serverID: serverA.connectionID.uuidString, userID: "user-1"): "pods"])

            // Another user on the same server, and the same user on another server, start fresh.
            let otherUser = LibraryConnectionKey(connectionID: serverA.connectionID, userID: "user-2")
            await store.connect(client: service(libraries), connectionKey: otherUser)
            #expect(store.lastLibraryID == nil)
            #expect(store.initialLibraryID == "books")
            await store.connect(client: service(libraries), connectionKey: serverB)
            #expect(store.lastLibraryID == nil)

            // A new store (a new scene, CarPlay, or a relaunch) reads the saved library.
            let other = LibraryStore(settings: settings)
            await other.connect(client: service(libraries), connectionKey: serverA)
            #expect(other.initialLibraryID == "pods")
        }
    }

    @Test func savedLibraryThatNoLongerExistsFallsBackToTheFirst() async throws {
        try await withLibrarySettings { settings in
            settings.setLastLibraryID("deleted", serverID: serverA.serverID, userID: serverA.userID)
            let store = LibraryStore(settings: settings)
            await store.connect(client: service([makeLibrary("books")]), connectionKey: serverA)

            #expect(store.lastLibraryID == "deleted")
            #expect(store.initialLibraryID == "books")
        }
    }

    @Test func switchingServersClearsTheOldServersData() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: service([makeLibrary("a-books")]), connectionKey: serverA)
            try await store.loadDetails(libraryID: "a-books")
            store.saveLastLibraryID("a-books")
            #expect(store.filterData(libraryID: "a-books") != nil)

            await store.connect(client: service([makeLibrary("b-books")]), connectionKey: serverB)
            #expect(store.connectionKey == serverB)
            #expect(store.libraries.map(\.id) == ["b-books"])
            #expect(store.details.isEmpty)
            #expect(store.library(id: "a-books") == nil)
            #expect(store.lastLibraryID == nil)
            #expect(store.initialLibraryID == "b-books")
        }
    }

    @Test func switchingServersOrClearingClearsProgress() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: service([makeLibrary("books")]), connectionKey: serverA)
            store.progress.apply(MediaProgress(id: "p", libraryItemId: "item", lastUpdate: 1))

            await store.connect(client: service([makeLibrary("books")]), connectionKey: serverA)
            #expect(store.progress.progress(libraryItemID: "item") != nil)

            await store.connect(client: service([makeLibrary("books")]), connectionKey: serverB)
            #expect(store.progress.progress(libraryItemID: "item") == nil)

            store.progress.apply(MediaProgress(id: "p", libraryItemId: "item", lastUpdate: 1))
            store.clear()
            #expect(store.progress.progress(libraryItemID: "item") == nil)
        }
    }

    @Test func reconnectingTheSameAccountKeepsDataWhileRefreshing() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: service([makeLibrary("books")]), connectionKey: serverA)
            try await store.loadDetails(libraryID: "books")

            let gate = GatedCalls<Void, [Library]>()
            var slow = service([])
            slow.librariesHandler = { try await gate.call(()) }
            var calls = gate.calls.makeAsyncIterator()
            let reconnect = Task { await store.connect(client: slow, connectionKey: serverA) }
            let call = try #require(await calls.next())

            #expect(store.isLoading)
            #expect(store.hasLoaded)
            #expect(store.libraries.map(\.id) == ["books"])
            #expect(store.details.keys.sorted() == ["books"])

            call.reply.resume(returning: [makeLibrary("books"), makeLibrary("pods")])
            await reconnect.value
            #expect(store.libraries.map(\.id) == ["books", "pods"])
            #expect(store.details.keys.sorted() == ["books"])
        }
    }

    @Test func overlappingRefreshesApplyTheLatest() async throws {
        try await withLibrarySettings { settings in
            let gate = GatedCalls<Void, [Library]>()
            var slow = FakeLibraryService()
            slow.librariesHandler = { try await gate.call(()) }
            var calls = gate.calls.makeAsyncIterator()
            let store = LibraryStore(settings: settings)

            let first = Task { await store.connect(client: slow, connectionKey: serverA) }
            let firstCall = try #require(await calls.next())
            let second = Task { await store.refresh() }
            let secondCall = try #require(await calls.next())

            secondCall.reply.resume(returning: [makeLibrary("new")])
            await second.value
            #expect(store.libraries.map(\.id) == ["new"])
            #expect(!store.isLoading)

            firstCall.reply.resume(returning: [makeLibrary("old")])
            await first.value
            #expect(store.libraries.map(\.id) == ["new"])
            #expect(!store.isLoading)
        }
    }

    @Test func overlappingDetailLoadsKeepTheLatest() async throws {
        try await withLibrarySettings { settings in
            let gate = GatedCalls<String, LibraryWithFilterData>()
            var slow = service([makeLibrary("books")])
            slow.libraryHandler = { id in try await gate.call(id) }
            var calls = gate.calls.makeAsyncIterator()
            let store = LibraryStore(settings: settings)
            await store.connect(client: slow, connectionKey: serverA)

            let first = Task { try await store.loadDetails(libraryID: "books") }
            let firstCall = try #require(await calls.next())
            let second = Task { try await store.loadDetails(libraryID: "books") }
            let secondCall = try #require(await calls.next())

            let newer = LibraryWithFilterData(
                library: makeLibrary("books"), filterData: LibraryFilterData(tags: ["new"]))
            let older = LibraryWithFilterData(
                library: makeLibrary("books"), filterData: LibraryFilterData(tags: ["old"]))
            secondCall.reply.resume(returning: newer)
            #expect(try await second.value == newer)
            firstCall.reply.resume(returning: older)
            // The caller still gets its own response, but the store keeps the latest request's.
            #expect(try await first.value == older)
            #expect(store.filterData(libraryID: "books")?.tags == ["new"])
        }
    }

    @Test func lastLibraryPersistsAcrossSettingsInstances() async throws {
        try await withLibraryDefaults { defaults in
            let first = LibraryStore(settings: AppSettings(defaults: defaults))
            await first.connect(client: service([makeLibrary("books"), makeLibrary("pods")]), connectionKey: serverA)
            first.saveLastLibraryID("pods")

            // A relaunch: new settings over the same store.
            let relaunched = LibraryStore(settings: AppSettings(defaults: defaults))
            await relaunched.connect(
                client: service([makeLibrary("books"), makeLibrary("pods")]), connectionKey: serverA)
            #expect(relaunched.lastLibraryID == "pods")
            #expect(relaunched.initialLibraryID == "pods")
        }
    }

    @Test func initialLibraryPrefersLastThenUserDefaultThenFirst() async throws {
        try await withLibrarySettings { settings in
            let libraries = [makeLibrary("one"), makeLibrary("two"), makeLibrary("three")]
            let store = LibraryStore(settings: settings)

            await store.connect(client: service(libraries), connectionKey: serverA, defaultLibraryID: "two")
            #expect(store.defaultLibraryID == "two")
            #expect(store.initialLibraryID == "two")

            store.saveLastLibraryID("three")
            #expect(store.initialLibraryID == "three")

            store.saveLastLibraryID("deleted")
            #expect(store.initialLibraryID == "two")

            await store.connect(client: service(libraries), connectionKey: serverA, defaultLibraryID: "inaccessible")
            #expect(store.initialLibraryID == "one")
        }
    }

    @Test func reconnectingWithoutADefaultKeepsTheAccountsDefault() async throws {
        try await withLibrarySettings { settings in
            let libraries = [makeLibrary("one"), makeLibrary("two")]
            let store = LibraryStore(settings: settings)
            await store.connect(client: service(libraries), connectionKey: serverA, defaultLibraryID: "two")

            await store.connect(client: service(libraries), connectionKey: serverA)
            #expect(store.defaultLibraryID == "two")
            #expect(store.initialLibraryID == "two")

            // Another account doesn't inherit it.
            await store.connect(client: service(libraries), connectionKey: serverB)
            #expect(store.defaultLibraryID == nil)
            #expect(store.initialLibraryID == "one")
        }
    }

    @Test func initialLibraryBeforeTheLibrariesLoad() async throws {
        try await withLibrarySettings { settings in
            var offline = FakeLibraryService()
            offline.librariesHandler = { throw TestError.offline }
            let store = LibraryStore(settings: settings)

            await store.connect(client: offline, connectionKey: serverA, defaultLibraryID: "default")
            #expect(!store.hasLoaded)
            #expect(store.error is TestError)
            #expect(store.initialLibraryID == "default")

            settings.setLastLibraryID("last", serverID: serverA.serverID, userID: serverA.userID)
            #expect(store.initialLibraryID == "last")

            // Once loaded, an empty list means there are no libraries.
            await store.connect(client: service([]), connectionKey: serverA)
            #expect(store.hasLoaded)
            #expect(store.initialLibraryID == nil)
        }
    }

    @Test func refreshUpdatesARenamedLibrary() async throws {
        try await withLibrarySettings { settings in
            let response = Locked([makeLibrary("books", name: "Books")])
            var fake = service([])
            fake.librariesHandler = { response.value }
            fake.libraryHandler = { id in
                LibraryWithFilterData(
                    library: makeLibrary(id, name: "Books"), filterData: LibraryFilterData(tags: ["t"]))
            }
            let store = LibraryStore(settings: settings)
            await store.connect(client: fake, connectionKey: serverA)
            try await store.loadDetails(libraryID: "books")

            response.value = [makeLibrary("books", name: "Audiobooks")]
            await store.refresh()
            #expect(store.library(id: "books")?.name == "Audiobooks")
            #expect(store.details["books"]?.library.name == "Audiobooks")
            #expect(store.filterData(libraryID: "books")?.tags == ["t"])
        }
    }

    @Test func responseForThePreviousServerIsDropped() async throws {
        try await withLibrarySettings { settings in
            let gate = GatedCalls<Void, [Library]>()
            var slowA = FakeLibraryService()
            slowA.librariesHandler = { try await gate.call(()) }
            var calls = gate.calls.makeAsyncIterator()
            let store = LibraryStore(settings: settings)

            let connectA = Task { await store.connect(client: slowA, connectionKey: serverA) }
            let callA = try #require(await calls.next())
            #expect(store.isLoading)

            await store.connect(client: service([makeLibrary("b-books")]), connectionKey: serverB)
            callA.reply.resume(returning: [makeLibrary("a-books")])
            await connectA.value

            #expect(store.connectionKey == serverB)
            #expect(store.libraries.map(\.id) == ["b-books"])
            #expect(!store.isLoading)
        }
    }

    @Test func clearDropsEverything() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: service([makeLibrary("books")]), connectionKey: serverA)
            try await store.loadDetails(libraryID: "books")
            store.saveLastLibraryID("books")

            store.clear()
            #expect(store.connectionKey == nil)
            #expect(store.client == nil)
            #expect(store.libraries.isEmpty)
            #expect(store.details.isEmpty)
            #expect(store.initialLibraryID == nil)
            #expect(store.lastLibraryID == nil)
            #expect(!store.hasLoaded)

            // Without an account there is nothing to refresh or save; the saved library stays.
            await store.refresh()
            store.saveLastLibraryID("other")
            #expect(store.libraries.isEmpty)
            #expect(settings.lastLibraryID(serverID: serverA.serverID, userID: serverA.userID) == "books")
        }
    }

    @Test func loadDetailsStoresFilterDataByLibrary() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: service([makeLibrary("one"), makeLibrary("two")]), connectionKey: serverA)

            let loaded = try await store.loadDetails(libraryID: "two")
            #expect(loaded.library.id == "two")
            #expect(store.filterData(libraryID: "two")?.genres == ["Genre of two"])
            #expect(store.filterData(libraryID: "one") == nil)
            // The detailed library replaces the listed one.
            #expect(store.libraries.map(\.name) == ["one", "two (detailed)"])
            #expect(store.mediaType(libraryID: "two") == .podcast)
        }
    }

    @Test func detailsForAClearedAccountAreDropped() async throws {
        try await withLibrarySettings { settings in
            let gate = GatedCalls<String, LibraryWithFilterData>()
            var slow = service([makeLibrary("books")])
            slow.libraryHandler = { id in try await gate.call(id) }
            var calls = gate.calls.makeAsyncIterator()
            let store = LibraryStore(settings: settings)
            await store.connect(client: slow, connectionKey: serverA)

            let load = Task { try await store.loadDetails(libraryID: "books") }
            let call = try #require(await calls.next())
            store.clear()
            call.reply.resume(
                returning: LibraryWithFilterData(library: makeLibrary("books"), filterData: LibraryFilterData()))

            await #expect(throws: CancellationError.self) { try await load.value }
            #expect(store.details.isEmpty)
        }
    }

    @Test func progressRequestedForThePreviousAccountIsDropped() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: service([]), connectionKey: serverA)
            let sameAccount = store.progress.beginSeed()
            await store.connect(client: service([]), connectionKey: serverA)
            #expect(store.progress.seed([MediaProgress(id: "p1", libraryItemId: "a1")], token: sameAccount))

            let previousAccount = store.progress.beginSeed()
            await store.connect(client: service([]), connectionKey: serverB)
            #expect(!store.progress.seed([MediaProgress(id: "p2", libraryItemId: "a2")], token: previousAccount))
            #expect(store.progress.progress(libraryItemID: "a1") == nil)
            #expect(store.progress.progress(libraryItemID: "a2") == nil)
        }
    }

    @Test func detailsRequestedBeforeARefreshAreNotStored() async throws {
        try await withLibrarySettings { settings in
            let response = Locked([makeLibrary("books", name: "Books"), makeLibrary("gone", name: "Gone")])
            let gate = GatedCalls<String, LibraryWithFilterData>()
            var fake = service([])
            fake.librariesHandler = { response.value }
            fake.libraryHandler = { id in try await gate.call(id) }
            var calls = gate.calls.makeAsyncIterator()
            let store = LibraryStore(settings: settings)
            await store.connect(client: fake, connectionKey: serverA)

            let loadBooks = Task { try await store.loadDetails(libraryID: "books") }
            let booksCall = try #require(await calls.next())
            let loadGone = Task { try await store.loadDetails(libraryID: "gone") }
            let goneCall = try #require(await calls.next())

            response.value = [makeLibrary("books", name: "Audiobooks")]
            await store.refresh()

            booksCall.reply.resume(
                returning: LibraryWithFilterData(
                    library: makeLibrary("books", name: "Books"), filterData: LibraryFilterData()))
            goneCall.reply.resume(
                returning: LibraryWithFilterData(
                    library: makeLibrary("gone", name: "Gone"), filterData: LibraryFilterData()))
            // The callers still get the responses, but the store keeps the refreshed state.
            #expect(try await loadBooks.value.library.name == "Books")
            #expect(try await loadGone.value.library.id == "gone")
            #expect(store.libraries.map(\.name) == ["Audiobooks"])
            #expect(store.details.isEmpty)

            // A load started after the refresh is stored.
            let reload = Task { try await store.loadDetails(libraryID: "books") }
            try #require(await calls.next()).reply.resume(
                returning: LibraryWithFilterData(
                    library: makeLibrary("books", name: "Audiobooks"), filterData: LibraryFilterData(tags: ["t"])))
            _ = try await reload.value
            #expect(store.filterData(libraryID: "books")?.tags == ["t"])
        }
    }

    @Test func refreshKeepsLibrariesOnFailureAndDropsRemovedOnes() async throws {
        try await withLibrarySettings { settings in
            let response = Locked<Result<[Library], TestError>>(.success([makeLibrary("one"), makeLibrary("two")]))
            var fake = service([])
            fake.librariesHandler = { try response.value.get() }
            let store = LibraryStore(settings: settings)
            await store.connect(client: fake, connectionKey: serverA)
            try await store.loadDetails(libraryID: "one")
            try await store.loadDetails(libraryID: "two")

            response.value = .failure(.offline)
            await store.refresh()
            #expect(store.error is TestError)
            #expect(store.libraries.count == 2)

            response.value = .success([makeLibrary("two")])
            await store.refresh()
            #expect(store.error == nil)
            #expect(store.libraries.map(\.id) == ["two"])
            #expect(Array(store.details.keys) == ["two"])
        }
    }
}
