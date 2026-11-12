import ABSCore
import Foundation
import Testing

@testable import ABSAPI

@Suite struct FeedEndpointsTests {
    @Test(arguments: [
        ("series-1", "series-1"), ("a/b?c#d%e f", "a%2Fb%3Fc%23d%25e%20f"), (".", "%2E"), ("..", "%2E%2E"),
    ])
    func pathsEncodeOneSegmentAndKeepTheProxyBase(id: String, encoded: String) throws {
        let base = try #require(URL(string: "https://abs.example/proxy/abs"))
        let request = RssFeedOpenRequest(
            serverAddress: "https://abs.example", slug: "s",
            metadataDetails: .init(preventIndexing: true, ownerName: "", ownerEmail: ""))
        for kind in RssFeedTarget.Kind.allCases {
            let open = FeedEndpoints.open(RssFeedTarget(kind, id: id), request)
            #expect(open.method == .post)
            #expect(open.requiresAuthentication)
            let openURL = try APIClient.url(base: base, path: open.path, query: open.query)
            #expect(
                openURL.absoluteString == "https://abs.example/proxy/abs/api/feeds/\(kind.rawValue)/\(encoded)/open")

            let current = FeedEndpoints.current(RssFeedTarget(kind, id: id))
            #expect(current.method == .get)
            let currentURL = try APIClient.url(base: base, path: current.path, query: current.query)
            let expected =
                switch kind {
                case .item: "items/\(encoded)?expanded=1&include=rssfeed"
                case .collection: "collections/\(encoded)?include=rssfeed"
                case .series: "series/\(encoded)?include=rssfeed"
                }
            #expect(currentURL.absoluteString == "https://abs.example/proxy/abs/api/\(expected)")
        }
        let close = FeedEndpoints.close(id: id)
        #expect(close.method == .post)
        let closeURL = try APIClient.url(base: base, path: close.path, query: close.query)
        #expect(closeURL.absoluteString == "https://abs.example/proxy/abs/api/feeds/\(encoded)/close")
    }

    @Test func openSendsTheLegacyBodyAndDecodesTheMinifiedFeed() async throws {
        let data = try fixture("rss-feed-open-2.37.2")
        let stub = StubServer { _ in
            StubResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
        }
        let request = RssFeedOpenRequest(
            serverAddress: "https://abs.example/abs", slug: "synthetic-series",
            metadataDetails: .init(preventIndexing: false, ownerName: "Ada Fixture", ownerEmail: ""))
        let response = try await client(for: stub).send(
            FeedEndpoints.open(RssFeedTarget(.series, id: "series-fixture"), request))
        #expect(
            response.feed
                == RssFeed(
                    id: "feed-fixture", entityType: "series", entityId: "series-fixture",
                    feedUrl: "/feed/synthetic-series",
                    meta: .init(title: "Synthetic Series", preventIndexing: true, ownerName: "Ada Fixture")))

        let sent = try #require(stub.requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path() == "/abs/api/feeds/series/series-fixture/open")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(sent.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(object.keys) == ["serverAddress", "slug", "metadataDetails"])
        #expect(object["serverAddress"] as? String == "https://abs.example/abs")
        #expect(object["slug"] as? String == "synthetic-series")
        let details = try #require(object["metadataDetails"] as? [String: Any])
        #expect(Set(details.keys) == ["preventIndexing", "ownerName", "ownerEmail"])
        #expect(details["preventIndexing"] as? Bool == false)
        #expect(details["ownerName"] as? String == "Ada Fixture")
        #expect(details["ownerEmail"] as? String == "")
    }

    @Test func openReportsTheServersPlainTextReason() async throws {
        let stub = StubServer { _ in .text("Slug already in use", status: 400) }
        let request = RssFeedOpenRequest(
            serverAddress: "https://abs.example", slug: "taken",
            metadataDetails: .init(preventIndexing: true, ownerName: "", ownerEmail: ""))
        await #expect(throws: APIError.http(status: 400, message: "Slug already in use")) {
            try await client(for: stub).send(FeedEndpoints.open(RssFeedTarget(.collection, id: "c"), request))
        }
    }

    @Test func closeAcceptsPlainOKWithoutABody() async throws {
        let stub = StubServer { _ in .text("OK", status: 200) }
        _ = try await client(for: stub).send(FeedEndpoints.close(id: "feed-fixture"))
        let sent = try #require(stub.requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path() == "/abs/api/feeds/feed-fixture/close")
        #expect(sent.httpBody == nil)
    }

    /// Another origin's 200 or 404 can't confirm the feed closed: the hop is declined instead.
    @Test(arguments: [(307, 200), (308, 404)])
    func closeRefusesCrossOriginRedirects(status: Int, otherStatus: Int) async throws {
        let other = StubServer { _ in .text("OK", status: otherStatus) }
        let stub = StubServer { _ in .redirect(to: "https://\(other.host)/api/feeds/feed-fixture/close", status: status)
        }

        await #expect(throws: APIError.redirectRefused(status: status)) {
            try await client(for: stub).send(FeedEndpoints.close(id: "feed-fixture"))
        }
        #expect(other.requests.isEmpty)
        #expect(stub.requests.count == 1)
    }

    @Test func currentDecodesTheFullCollectionFeedAndIgnoresTheRest() async throws {
        let data = try fixture("collection-rss-feed-2.37.2")
        let stub = StubServer { _ in StubResponse(status: 200, body: data) }
        let lookup = try await client(for: stub).send(
            FeedEndpoints.current(RssFeedTarget(.collection, id: "collection-fixture")))
        let feed = try #require(lookup.rssFeed)
        #expect(feed.id == "feed-collection")
        #expect(feed.entityType == "collection")
        #expect(feed.feedUrl == "/feed/synthetic-collection")
        #expect(feed.meta?.preventIndexing == false)
        #expect(feed.meta?.ownerName == nil)
        #expect(feed.meta?.ownerEmail == "owner@example.com")
    }

    @Test(arguments: [#"{"id":"s","name":"Series","rssFeed":null}"#, #"{"id":"s","name":"Series"}"#])
    func currentIsNilWithoutAnOpenFeed(json: String) async throws {
        let stub = StubServer { _ in .json(json) }
        let lookup = try await client(for: stub).send(FeedEndpoints.current(RssFeedTarget(.series, id: "s")))
        #expect(lookup.rssFeed == nil)
    }

    @Test(arguments: [
        ("/feed/slug", "https://abs.example/abs", "https://abs.example/abs/feed/slug"),
        ("/feed/slug", "https://abs.example/abs/", "https://abs.example/abs/feed/slug"),
        ("feed/slug", "http://10.0.0.2:13378", "http://10.0.0.2:13378/feed/slug"),
        ("https://other.example/feed/slug", "https://abs.example", "https://other.example/feed/slug"),
    ])
    func feedURLJoinsTheRelativePathToTheServer(feedURL: String, server: String, expected: String) throws {
        let feed = RssFeed(id: "f", entityType: "series", entityId: "s", feedUrl: feedURL)
        #expect(feed.url(on: try #require(URL(string: server)))?.absoluteString == expected)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func client(for stub: StubServer) throws -> APIClient {
        APIClient(
            configuration: try APIClientConfiguration(baseURL: stub.baseURL),
            tokenProvider: InMemoryTokenProvider(), sessionConfiguration: stub.sessionConfiguration())
    }
}
