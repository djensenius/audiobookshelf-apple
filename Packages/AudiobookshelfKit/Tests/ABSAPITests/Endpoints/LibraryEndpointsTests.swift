import ABSCore
import Foundation
import Testing

@testable import ABSAPI

private func url<Response>(_ endpoint: Endpoint<Response>) throws -> String {
    let base = try #require(URL(string: "https://abs.example/abs"))
    return try APIClient.url(base: base, path: endpoint.path, query: endpoint.query).absoluteString
}

private let server = "https://abs.example/abs"
private let listSuffix = "minified=1&include=rssfeed,numEpisodesIncomplete"

@Suite struct LibraryEndpointsTests {
    @Test func libraries() throws {
        let endpoint = LibraryEndpoints.libraries()
        #expect(endpoint.method == .get)
        #expect(endpoint.requiresAuthentication)
        #expect(try url(endpoint) == "\(server)/api/libraries")
    }

    @Test func libraryWithFilterData() throws {
        #expect(try url(LibraryEndpoints.library(id: "lib1")) == "\(server)/api/libraries/lib1?include=filterdata")
    }

    @Test func personalized() throws {
        #expect(
            try url(LibraryEndpoints.personalized(libraryID: "lib1"))
                == "\(server)/api/libraries/lib1/personalized?\(listSuffix)")
    }

    @Test func search() throws {
        #expect(
            try url(LibraryEndpoints.search(libraryID: "lib1", query: "dune & co+"))
                == "\(server)/api/libraries/lib1/search?q=dune%20%26%20co%2B")
        #expect(
            try url(LibraryEndpoints.search(libraryID: "lib1", query: "x", limit: 5))
                == "\(server)/api/libraries/lib1/search?q=x&limit=5")
    }

    @Test func searchOmitsLimitWhenNil() {
        #expect(LibraryEndpoints.search(libraryID: "lib1", query: "x").query.map(\.name) == ["q"])
    }

    @Test func searchPreservesWhitespaceZeroLimitAndEscapedLibraryID() throws {
        let endpoint = LibraryEndpoints.search(libraryID: "a/b?", query: " x ", limit: 0)
        #expect(endpoint.method == .get)
        #expect(endpoint.requiresAuthentication)
        #expect(
            try url(endpoint) == "\(server)/api/libraries/a%2Fb%3F/search?q=%20x%20&limit=0")
    }

    @Test(arguments: [
        ("a/b?c#d%e f", "a%2Fb%3Fc%23d%25e%20f"), (".", "%2E"), ("..", "%2E%2E"), ("ok-1_2.3~", "ok-1_2.3~"),
    ])
    func idsAreEncodedAsOnePathSegment(id: String, encoded: String) throws {
        #expect(try url(LibraryEndpoints.library(id: id)) == "\(server)/api/libraries/\(encoded)?include=filterdata")
        #expect(
            try url(LibraryEndpoints.items(libraryID: id))
                == "\(server)/api/libraries/\(encoded)/items?\(listSuffix)")
        #expect(
            try url(ItemEndpoints.item(id: id)) == "\(server)/api/items/\(encoded)?expanded=1&include=rssfeed")
        #expect(try url(ItemEndpoints.series(id: id)) == "\(server)/api/series/\(encoded)")
        #expect(try url(ItemEndpoints.collection(id: id)) == "\(server)/api/collections/\(encoded)")
        #expect(try url(ItemEndpoints.playlist(id: id)) == "\(server)/api/playlists/\(encoded)")
        #expect(
            try url(ItemEndpoints.ebook(itemID: id, fileID: id)) == "\(server)/api/items/\(encoded)/ebook/\(encoded)")
    }

    @Test func authors() throws {
        #expect(try url(LibraryEndpoints.authors(libraryID: "lib1")) == "\(server)/api/libraries/lib1/authors")
    }

    @Test func recentEpisodes() throws {
        let endpoint = LibraryEndpoints.recentEpisodes(libraryID: "lib1")
        #expect(endpoint.method == .get)
        #expect(endpoint.requiresAuthentication)
        #expect(try url(endpoint) == "\(server)/api/libraries/lib1/recent-episodes?limit=50&page=0")
        #expect(
            try url(LibraryEndpoints.recentEpisodes(libraryID: "lib1", page: 3))
                == "\(server)/api/libraries/lib1/recent-episodes?limit=50&page=3")
        #expect(
            try url(LibraryEndpoints.recentEpisodes(libraryID: "lib1", page: 1, limit: 1))
                == "\(server)/api/libraries/lib1/recent-episodes?limit=1&page=1")
    }

    @Test func pagedItemsUseLegacyQueryOrder() throws {
        let query = LibraryQuery(
            sort: "media.metadata.title", descending: false, filter: .progress("finished"), page: 1, limit: 30,
            collapseSeries: true)
        #expect(
            try url(LibraryEndpoints.items(libraryID: "lib1", query: query))
                == "\(server)/api/libraries/lib1/items?filter=progress.ZmluaXNoZWQ%253D&sort=media.metadata.title"
                + "&desc=0&collapseseries=1&limit=30&page=1&\(listSuffix)")
    }

    @Test func pagedGroupings() throws {
        let query = LibraryQuery(sort: "name", page: 0, limit: 20)
        let suffix = "sort=name&desc=0&limit=20&page=0&\(listSuffix)"
        #expect(
            try url(LibraryEndpoints.series(libraryID: "lib1", query: query))
                == "\(server)/api/libraries/lib1/series?\(suffix)")
        #expect(
            try url(LibraryEndpoints.collections(libraryID: "lib1", query: query))
                == "\(server)/api/libraries/lib1/collections?\(suffix)")
        #expect(
            try url(LibraryEndpoints.playlists(libraryID: "lib1", query: query))
                == "\(server)/api/libraries/lib1/playlists?\(suffix)")
    }

    @Test func pagedItemsSendAndDecodeThroughClient() async throws {
        let stub = StubServer { _ in
            .json(
                #"{"results":[{"id":"li1","libraryId":"lib1","mediaType":"book","media":{"id":"b1","metadata":{"title":"One"}}}],"total":1,"limit":"10","page":"0"}"#
            )
        }
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: stub.baseURL),
            tokenProvider: InMemoryTokenProvider(),
            sessionConfiguration: stub.sessionConfiguration()
        )

        let page = try await client.send(LibraryEndpoints.items(libraryID: "lib1", query: LibraryQuery(limit: 10)))

        #expect(page.results.map(\.id) == ["li1"])
        #expect(page.total == 1)
        #expect(page.limit == 10)
        let request = try #require(stub.requests.first)
        #expect(request.url?.path() == "/abs/api/libraries/lib1/items")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
    }
}

@Suite struct ItemEndpointsTests {
    @Test func expandedItem() throws {
        #expect(try url(ItemEndpoints.item(id: "li1")) == "\(server)/api/items/li1?expanded=1&include=rssfeed")
    }

    @Test func groupingsByID() throws {
        #expect(try url(ItemEndpoints.series(id: "ser1")) == "\(server)/api/series/ser1")
        #expect(try url(ItemEndpoints.collection(id: "col1")) == "\(server)/api/collections/col1")
        #expect(try url(ItemEndpoints.playlist(id: "pl1")) == "\(server)/api/playlists/pl1")
    }

    @Test func ebookIsAuthenticatedRawData() throws {
        let primary = ItemEndpoints.ebook(itemID: "li1")
        #expect(primary.requiresAuthentication)
        #expect(try url(primary) == "\(server)/api/items/li1/ebook")
        #expect(try url(ItemEndpoints.ebook(itemID: "li1", fileID: "123")) == "\(server)/api/items/li1/ebook/123")
    }
}
