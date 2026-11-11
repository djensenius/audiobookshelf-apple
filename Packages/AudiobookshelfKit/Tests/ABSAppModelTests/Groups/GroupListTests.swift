import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

private typealias F = GroupFixtures

private struct FixedTokens: TokenProvider {
    func tokens() async -> AuthTokens? { AuthTokens(accessToken: "access", refreshToken: "refresh") }
    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool { false }
    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool { false }
}

@MainActor
@Suite struct GroupListTests {
    @Test func collectionsMapToSlimRowsWithAtMostFourCovers() async throws {
        let requests = Locked<[String]>([])
        let books = (1...6).map { F.book("b\($0)") }
        let service = FakeGroupsService(collectionsHandler: { libraryID, page, limit in
            requests.value.append("\(libraryID):\(page):\(limit)")
            return PagedResults(
                results: [
                    F.collection("c1", name: "Favorites", books: books),
                    F.collection("c2", name: "Empty", books: []),
                    F.collection("c3", books: [F.book("x", cover: nil), F.book("y")]),
                ], total: 3, limit: limit, page: page)
        })
        let list = ItemListModel.collections(service: service, libraryID: "lib")

        await list.loadNextPage()?.value

        #expect(requests.value == ["lib:0:20"])
        #expect(list.items.map(\.id) == ["c1", "c2", "c3"])
        let favorites = list.items[0]
        #expect(favorites.kind == .collection)
        #expect(favorites.name == "Favorites")
        #expect(favorites.itemCount == 6)
        #expect(favorites.covers.map(\.entityID) == ["b1", "b2", "b3", "b4"])
        #expect(list.items[1].itemCount == 0)
        #expect(list.items[1].covers.isEmpty)
        // A book without a cover is skipped, not counted against the four.
        #expect(list.items[2].itemCount == 2)
        #expect(list.items[2].covers.map(\.entityID) == ["y"])
        #expect(list.reachedEnd)
    }

    @Test func playlistsCountMixedItemsAndShowEachCoverOnce() async throws {
        let show = F.podcast("show")
        let service = FakeGroupsService(playlistsHandler: { _, page, limit in
            PagedResults(
                results: [
                    F.playlist(
                        "p1", name: "Commute",
                        items: [
                            F.episodeEntry(show, F.episode("e1")), F.bookEntry(F.book("b1")),
                            F.episodeEntry(show, F.episode("e2")), PlaylistItem(libraryItemId: "gone"),
                        ])
                ], total: 1, limit: limit, page: page)
        })
        let list = ItemListModel.playlists(service: service, libraryID: "lib")

        await list.loadNextPage()?.value

        let commute = try #require(list.items.first)
        #expect(commute.kind == .playlist)
        #expect(commute.name == "Commute")
        #expect(commute.itemCount == 4)
        #expect(commute.covers.map(\.entityID) == ["show", "b1"])
    }

    @Test func emptyListsReachTheEnd() async throws {
        let list = ItemListModel.playlists(service: FakeGroupsService(), libraryID: "lib")

        await list.loadNextPage()?.value

        #expect(list.items.isEmpty)
        #expect(list.reachedEnd)
        #expect(list.error == nil)
    }

    @Test func switchingLibrariesReloadsForTheNewLibrary() async throws {
        let requested = Locked<[String]>([])
        let service = FakeGroupsService(collectionsHandler: { libraryID, page, limit in
            requested.value.append(libraryID)
            return PagedResults(
                results: [F.collection("c-\(libraryID)", books: [])], total: 1, limit: limit, page: page)
        })
        let list = ItemListModel.collections(service: service, libraryID: "a")
        await list.loadNextPage()?.value

        await list.setQuery("b")?.value

        #expect(requested.value == ["a", "b"])
        #expect(list.items.map(\.id) == ["c-b"])
    }

    @Test func malformedRowsAndMembersDontDropTheList() async throws {
        // The second collection has no name; the first has one malformed book.
        let json = """
            {"results":[{"id":"c1","libraryId":"lib","name":"Kept","books":[{"id":"b1","libraryId":"lib",\
            "mediaType":"book","media":{"id":"m1","metadata":{"title":"One"},"coverPath":"/c.jpg"}},\
            {"id":7}]},{"id":"c2","libraryId":"lib"}],"total":2,"limit":20,"page":0}
            """
        let page = try JSONDecoder().decode(PagedResults<LibraryCollection>.self, from: Data(json.utf8))
        let service = FakeGroupsService(collectionsHandler: { _, _, _ in page })
        let list = ItemListModel.collections(service: service, libraryID: "lib")

        await list.loadNextPage()?.value

        #expect(list.items.map(\.id) == ["c1"])
        #expect(list.items.first?.itemCount == 1)
        #expect(list.reachedEnd)
    }

    @Test func apiClientSendsPagingWithoutSortOrFilterAndReportsNotFound() async throws {
        let host = "\(UUID().uuidString.lowercased()).stub.test"
        StubURLProtocol.register(host: host) { request in
            switch request.url?.path() {
            case "/api/libraries/lib/playlists", "/api/libraries/lib/collections":
                .json(#"{"results":[],"total":0,"limit":20,"page":1}"#)
            default: StubResponse(status: 404)
            }
        }
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: try #require(URL(string: "https://\(host)"))),
            tokenProvider: FixedTokens(), sessionConfiguration: StubURLProtocol.sessionConfiguration())

        _ = try await client.playlistsPage(libraryID: "lib", page: 1, limit: 20)
        _ = try await client.collectionsPage(libraryID: "lib", page: 1, limit: 20)
        await #expect(throws: APIError.notFound) { try await client.playlistDetail(id: "deleted") }
        await #expect(throws: APIError.notFound) { try await client.collectionDetail(id: "deleted") }

        let requests = StubURLProtocol.requests(host: host)
        #expect(
            requests.map { $0.url?.path() } == [
                "/api/libraries/lib/playlists", "/api/libraries/lib/collections", "/api/playlists/deleted",
                "/api/collections/deleted",
            ])
        for request in requests.prefix(2) {
            let url = try #require(request.url)
            let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name)
            #expect(names == ["limit", "page", "minified", "include"])
        }
    }
}
