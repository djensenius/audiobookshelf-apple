import ABSCore
import Foundation
import Testing

@testable import ABSAPI

@Suite struct PodcastEndpointsTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func client(_ stub: StubServer) throws -> APIClient {
        APIClient(
            configuration: try APIClientConfiguration(baseURL: stub.baseURL.appendingPathComponent("proxy")),
            tokenProvider: InMemoryTokenProvider(), sessionConfiguration: stub.sessionConfiguration())
    }

    /// The path `client(_:)` sends `path` to, below the stub's proxy base.
    private func path(_ stub: StubServer, _ path: String) -> String {
        stub.baseURL.appendingPathComponent("proxy").path() + path
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func directorySearchEncodesTermAndCountryAndDecodesResults() async throws {
        let data = try fixture("podcast-directory-search")
        let stub = StubServer { _ in
            StubResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
        }
        let results = try await client(stub).send(PodcastEndpoints.searchDirectory(term: "a+b & c", country: "ca"))

        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.url?.path() == path(stub, "/api/search/podcast"))
        #expect(request.url?.query() == "term=a%2Bb%20%26%20c&country=ca")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")

        #expect(results.count == 2)
        let first = try #require(results.first)
        #expect(first.itunesID == "1234567890" && first.itunesArtistID == "987654")
        #expect(first.title == "Synthetic Cast" && first.artistName == "Example Studio")
        #expect(first.genres == ["Fiction", "Podcasts"] && first.trackCount == 42 && first.explicit)
        #expect(first.feedURL == "https://feeds.example.com/synthetic.xml")
        #expect(first.cover == "https://images.example.com/synthetic/600x600bb.jpg")
        #expect(first.pageURL == "https://podcasts.example.com/synthetic-cast/id1234567890")
        #expect(first.descriptionPlain == "A synthetic show." && first.releaseDate == "2026-10-01T12:00:00Z")
        let second = try #require(results.last)
        #expect(second.itunesID == "222" && second.itunesArtistID == nil)
        #expect(second.feedURL == nil && second.cover == nil && second.trackCount == nil && !second.explicit)
    }

    @Test func directorySearchWithoutCountryLeavesItToTheServer() throws {
        for country in [nil, ""] {
            let endpoint = PodcastEndpoints.searchDirectory(term: "news", country: country)
            #expect(endpoint.method == .get && endpoint.requiresAuthentication)
            #expect(endpoint.query == [URLQueryItem(name: "term", value: "news")])
        }
    }

    @Test func directoryRowsWithOddTypesStillDecode() throws {
        let json = #"[{"id":"abc","title":5,"genres":["A",3,null],"trackCount":"7","explicit":"yes"}, {}]"#
        let results = try JSONDecoder().decode([PodcastDirectoryResult].self, from: Data(json.utf8))
        #expect(results.count == 2)
        #expect(results[0].itunesID == "abc" && results[0].title == "" && results[0].genres == ["A"])
        #expect(results[0].trackCount == nil && !results[0].explicit)
        #expect(results[1].title == "" && results[1].feedURL == nil)
    }

    @Test func feedLookupPostsTheURLAndDecodesTheFeed() async throws {
        let data = try fixture("podcast-feed")
        let stub = StubServer { _ in
            StubResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
        }
        let url = "https://feeds.example.com/synthetic.xml?a=1&b=2"
        let response = try await client(stub).send(PodcastEndpoints.feed(rssFeed: url))

        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == path(stub, "/api/podcasts/feed"))
        #expect(request.url?.query() == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        let object = try body(request)
        #expect(Set(object.keys) == ["rssFeed"])
        #expect(object["rssFeed"] as? String == url)

        let feed = response.podcast
        #expect(feed.metadata.title == "Synthetic Cast" && feed.metadata.author == "Example Studio")
        #expect(feed.metadata.feedURL == "https://feeds.example.com/synthetic.xml")
        #expect(feed.metadata.image == "https://feeds.example.com/synthetic.jpg")
        #expect(feed.metadata.categories == ["Arts", "Arts:Books"])
        #expect(feed.metadata.language == "en" && feed.metadata.type == "episodic")
        #expect(feed.metadata.descriptionPlain == "A synthetic show.")
        #expect(feed.metadata.explicit == "yes" && feed.metadata.isExplicit)
        // The string entry is skipped; the count is the server's.
        #expect(feed.episodes.map(\.title) == ["Episode Two", "Episode One"])
        #expect(feed.episodes.first?.enclosureURL == "https://feeds.example.com/ep2.mp3")
        #expect(feed.numEpisodes == 3)
    }

    @Test(arguments: [("yes", true), ("True", true), ("explicit", true), ("no", false), ("clean", false)])
    func explicitFlag(value: String, isExplicit: Bool) {
        #expect(PodcastFeedMetadata(explicit: value).isExplicit == isExplicit)
    }

    @Test func feedWithoutMetadataFailsToDecode() async throws {
        let stub = StubServer { _ in .json(#"{"podcast":{"episodes":[]}}"#) }
        await #expect(throws: APIError.self) {
            try await client(stub).send(PodcastEndpoints.feed(rssFeed: "https://example.com/feed"))
        }
    }

    @Test func createPostsLegacyBodyAndReturnsTheItem() async throws {
        let data = try fixture("expanded-item-podcast-2.26.0")
        let stub = StubServer { _ in
            StubResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
        }
        let request = NewPodcastRequest(
            libraryID: "lib", folderID: "folder", path: "/podcasts/Synthetic Cast",
            media: .init(
                metadata: .init(
                    title: "Synthetic Cast", author: "Example Studio", description: "<p>Show</p>",
                    releaseDate: "2026-10-01T12:00:00Z", genres: ["Fiction"],
                    feedURL: "https://feeds.example.com/synthetic.xml", imageURL: "https://images.example.com/a.jpg",
                    itunesPageURL: "https://podcasts.example.com/id1", itunesID: "1", itunesArtistID: "2",
                    language: "en", explicit: true, type: "serial"),
                autoDownloadEpisodes: true))
        let item = try await client(stub).send(PodcastEndpoints.create(request))
        #expect(item.id == "item-podcast")

        let sent = try #require(stub.requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path() == path(stub, "/api/podcasts"))
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        let object = try body(sent)
        #expect(Set(object.keys) == ["libraryId", "folderId", "path", "media"])
        #expect(object["libraryId"] as? String == "lib" && object["folderId"] as? String == "folder")
        #expect(object["path"] as? String == "/podcasts/Synthetic Cast")
        let media = try #require(object["media"] as? [String: Any])
        #expect(Set(media.keys) == ["metadata", "autoDownloadEpisodes"])
        #expect(media["autoDownloadEpisodes"] as? Bool == true)
        let metadata = try #require(media["metadata"] as? [String: Any])
        #expect(
            Set(metadata.keys) == [
                "title", "author", "description", "releaseDate", "genres", "feedUrl", "imageUrl", "itunesPageUrl",
                "itunesId", "itunesArtistId", "language", "explicit", "type",
            ])
        #expect(metadata["feedUrl"] as? String == "https://feeds.example.com/synthetic.xml")
        #expect(metadata["imageUrl"] as? String == "https://images.example.com/a.jpg")
        #expect(metadata["itunesId"] as? String == "1" && metadata["itunesArtistId"] as? String == "2")
        #expect(metadata["genres"] as? [String] == ["Fiction"])
        #expect(metadata["explicit"] as? Bool == true && metadata["type"] as? String == "serial")
    }

    @Test func createOmitsMissingMetadata() async throws {
        let data = try fixture("expanded-item-podcast-2.26.0")
        let stub = StubServer { _ in StubResponse(status: 200, body: data) }
        let request = NewPodcastRequest(
            libraryID: "lib", folderID: "folder", path: "/p/T",
            media: .init(metadata: .init(title: "T", feedURL: "https://f"), autoDownloadEpisodes: false))
        _ = try await client(stub).send(PodcastEndpoints.create(request))
        let sent = try #require(stub.requests.first)
        let media = try #require(try body(sent)["media"] as? [String: Any])
        #expect(media["autoDownloadEpisodes"] as? Bool == false)
        let metadata = try #require(media["metadata"] as? [String: Any])
        #expect(Set(metadata.keys) == ["title", "genres", "feedUrl", "explicit"])
    }

    @Test func createKeepsTheServersPlainTextError() async throws {
        let stub = StubServer { request in
            request.url?.path().hasSuffix("/feed") == true
                ? .text("Forbidden", status: 403) : .text("Podcast already exists", status: 400)
        }
        let client = try client(stub)
        let request = NewPodcastRequest(
            libraryID: "lib", folderID: "folder", path: "/p/T",
            media: .init(metadata: .init(title: "T", feedURL: "https://f"), autoDownloadEpisodes: false))
        let error = await #expect(throws: APIError.self) { try await client.send(PodcastEndpoints.create(request)) }
        #expect(error == .http(status: 400, message: "Podcast already exists"))
        let forbidden = await #expect(throws: APIError.self) {
            try await client.send(PodcastEndpoints.feed(rssFeed: "https://f"))
        }
        guard case .forbidden? = forbidden else {
            Issue.record("Expected forbidden, got \(String(describing: forbidden))")
            return
        }
    }
}
