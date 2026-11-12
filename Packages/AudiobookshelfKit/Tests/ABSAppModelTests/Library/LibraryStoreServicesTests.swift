import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

private let serverA = LibraryConnectionKey(
    connectionID: UUID(uuidString: "00000000-0000-0000-0000-00000000000A") ?? UUID(), userID: "user-1")
private let serverB = LibraryConnectionKey(
    connectionID: UUID(uuidString: "00000000-0000-0000-0000-00000000000B") ?? UUID(), userID: "user-1")

/// The fake client `client` received a call to `method`.
private struct Reached: Error, Equatable {
    let client: String
    let method: String
}

/// A client implementing every feature service. ``item(id:)`` answers through `itemHandler`;
/// the other feature calls throw ``Reached``.
private struct FeatureClient: LibraryService, ItemDetailService, SearchService, SeriesAuthorsService, GroupsService,
    LatestEpisodesService
{
    var name = "client"
    var library = FakeLibraryService()
    var itemHandler: @Sendable (String) async throws -> LibraryItem = { _ in throw TestError.unexpected }

    private func reached(_ method: String = #function) -> Reached { Reached(client: name, method: method) }

    func libraries() async throws -> [Library] { try await library.libraries() }
    func library(id: String) async throws -> LibraryWithFilterData { try await library.library(id: id) }
    func personalizedShelves(libraryID: String) async throws -> [Shelf] { throw reached() }
    func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem> { throw reached() }
    func item(id: String) async throws -> LibraryItem { try await itemHandler(id) }
    func searchLibrary(id: String, query: String, limit: Int?) async throws -> LibrarySearchResults { throw reached() }
    func seriesPage(libraryID: String, query: LibraryQuery) async throws -> PagedResults<Series> { throw reached() }
    func authorList(libraryID: String) async throws -> [Author] { throw reached() }
    func seriesDetail(id: String) async throws -> SeriesDetailResponse { throw reached() }
    func authorDetail(id: String) async throws -> AuthorDetailResponse { throw reached() }
    func filteredBooksPage(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem> {
        throw reached()
    }
    func collectionsPage(libraryID: String, page: Int, limit: Int) async throws -> PagedResults<LibraryCollection> {
        throw reached()
    }
    func playlistsPage(libraryID: String, page: Int, limit: Int) async throws -> PagedResults<Playlist> {
        throw reached()
    }
    func collectionDetail(id: String) async throws -> LibraryCollection { throw reached() }
    func playlistDetail(id: String) async throws -> Playlist { throw reached() }
    func recentEpisodes(libraryID: String, page: Int, limit: Int) async throws -> RecentEpisodesPage {
        throw reached()
    }
}

/// A client that knows its server address.
private struct AddressedClient: LibraryService, ServerURLProviding {
    var library = FakeLibraryService()
    let url: URL

    func libraries() async throws -> [Library] { try await library.libraries() }
    func library(id: String) async throws -> LibraryWithFilterData { try await library.library(id: id) }
    func personalizedShelves(libraryID: String) async throws -> [Shelf] { [] }
    func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem> {
        try await library.items(libraryID: libraryID, query: query)
    }
    func serverURL() async -> URL { url }
}

/// A feature request and the fake client method it must reach.
struct StoreServiceForwarding: Sendable, CustomTestStringConvertible {
    let method: String
    let call: @Sendable (LibraryStoreServices) async throws -> Void
    var testDescription: String { method }
}

private let forwardings: [StoreServiceForwarding] = [
    StoreServiceForwarding(method: "personalizedShelves(libraryID:)") {
        _ = try await $0.personalizedShelves(libraryID: "l")
    },
    StoreServiceForwarding(method: "items(libraryID:query:)") {
        _ = try await $0.items(libraryID: "l", query: LibraryQuery())
    },
    StoreServiceForwarding(method: "searchLibrary(id:query:limit:)") {
        _ = try await $0.searchLibrary(id: "l", query: "q", limit: 5)
    },
    StoreServiceForwarding(method: "seriesPage(libraryID:query:)") {
        _ = try await $0.seriesPage(libraryID: "l", query: LibraryQuery())
    },
    StoreServiceForwarding(method: "authorList(libraryID:)") { _ = try await $0.authorList(libraryID: "l") },
    StoreServiceForwarding(method: "seriesDetail(id:)") { _ = try await $0.seriesDetail(id: "s") },
    StoreServiceForwarding(method: "authorDetail(id:)") { _ = try await $0.authorDetail(id: "a") },
    StoreServiceForwarding(method: "filteredBooksPage(libraryID:query:)") {
        _ = try await $0.filteredBooksPage(libraryID: "l", query: LibraryQuery())
    },
    StoreServiceForwarding(method: "collectionsPage(libraryID:page:limit:)") {
        _ = try await $0.collectionsPage(libraryID: "l", page: 0, limit: 10)
    },
    StoreServiceForwarding(method: "playlistsPage(libraryID:page:limit:)") {
        _ = try await $0.playlistsPage(libraryID: "l", page: 0, limit: 10)
    },
    StoreServiceForwarding(method: "collectionDetail(id:)") { _ = try await $0.collectionDetail(id: "c") },
    StoreServiceForwarding(method: "playlistDetail(id:)") { _ = try await $0.playlistDetail(id: "p") },
    StoreServiceForwarding(method: "recentEpisodes(libraryID:page:limit:)") {
        _ = try await $0.recentEpisodes(libraryID: "l", page: 0, limit: 50)
    },
]

@MainActor
@Suite struct LibraryStoreServicesTests {
    @Test func noServicesWithoutAnAccount() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            #expect(store.makeServices() == nil)
            await store.connect(client: FeatureClient(), connectionKey: serverA)
            #expect(store.makeServices()?.connectionKey == serverA)
            store.clear()
            #expect(store.makeServices() == nil)
        }
    }

    @Test(arguments: forwardings)
    func requestsReachTheClient(_ forwarding: StoreServiceForwarding) async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: FeatureClient(), connectionKey: serverA)
            let services = try #require(store.makeServices())
            await #expect(throws: Reached(client: "client", method: forwarding.method)) {
                try await forwarding.call(services)
            }
        }
    }

    @Test func requestsGoToTheCurrentClientOfTheAccount() async throws {
        try await withLibrarySettings { settings in
            func client(_ name: String) -> FeatureClient {
                var client = FeatureClient(name: name)
                client.itemHandler = { _ in try makeLibraryItem(name) }
                return client
            }
            let store = LibraryStore(settings: settings)
            await store.connect(client: client("old"), connectionKey: serverA)
            let services = try #require(store.makeServices())
            #expect(try await services.item(id: "i").id == "old")

            // The same account reconnects with a new client (new tokens or server address).
            await store.connect(client: client("new"), connectionKey: serverA)
            #expect(try await services.item(id: "i").id == "new")

            // Another account: the services don't reach its client.
            await store.connect(client: client("other"), connectionKey: serverB)
            await #expect(throws: CancellationError.self) { try await services.item(id: "i") }
        }
    }

    @Test func repliesFromBeforeAClearOrSwitchAreCancellations() async throws {
        enum Lifecycle: CaseIterable { case clear, switchAccount }
        for lifecycle in Lifecycle.allCases {
            try await withLibrarySettings { settings in
                let gate = GatedCalls<String, LibraryItem>()
                var calls = gate.calls.makeAsyncIterator()
                var slow = FeatureClient()
                slow.itemHandler = { id in try await gate.call(id) }
                let store = LibraryStore(settings: settings)
                await store.connect(client: slow, connectionKey: serverA)
                let services = try #require(store.makeServices())

                let request = Task { try await services.item(id: "i") }
                let call = try #require(await calls.next())
                switch lifecycle {
                case .clear: store.clear()
                case .switchAccount: await store.connect(client: FeatureClient(), connectionKey: serverB)
                }
                call.reply.resume(returning: try makeLibraryItem("stale"))
                await #expect(throws: CancellationError.self, "\(lifecycle)") { try await request.value }
            }
        }
    }

    @Test func clientWithoutTheServiceThrowsServiceUnavailable() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            await store.connect(client: FakeLibraryService(), connectionKey: serverA)
            let services = try #require(store.makeServices())
            await #expect(throws: LibraryStoreError.serviceUnavailable("ItemDetailService")) {
                try await services.item(id: "i")
            }
            // Library requests still reach the client.
            #expect(try await services.libraries().isEmpty)
        }
    }

    @Test func serverURLComesFromTheCurrentClient() async throws {
        try await withLibrarySettings { settings in
            let store = LibraryStore(settings: settings)
            let url = try #require(URL(string: "https://abs.example.com/audiobookshelf"))
            await store.connect(client: AddressedClient(url: url), connectionKey: serverA)
            let services = try #require(store.makeServices())
            #expect(try await services.serverURL() == url)

            // A reconnect of the same account to a new address is followed.
            let moved = try #require(URL(string: "https://new.example.com"))
            await store.connect(client: AddressedClient(url: moved), connectionKey: serverA)
            #expect(try await services.serverURL() == moved)

            // A client that can't tell, and no client at all.
            await store.connect(client: FakeLibraryService(), connectionKey: serverA)
            await #expect(throws: LibraryStoreError.serviceUnavailable("ServerURLProviding")) {
                try await services.serverURL()
            }
            store.clear()
            await #expect(throws: CancellationError.self) { try await services.serverURL() }
        }
    }
}
