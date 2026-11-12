import ABSCore
import Foundation
import Testing

@testable import ABSAPI

@Suite struct PodcastEpisodeManagementEndpointsTests {
    private func makeClient(_ stub: StubServer) throws -> APIClient {
        APIClient(
            configuration: try APIClientConfiguration(baseURL: stub.baseURL),
            tokenProvider: InMemoryTokenProvider(),
            sessionConfiguration: stub.sessionConfiguration()
        )
    }

    private func feedFixture() throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: "podcast-feed-episodes-2.26.0", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func body(_ request: URLRequest) throws -> Any {
        try JSONSerialization.jsonObject(with: try #require(request.httpBody))
    }

    @Test func feedEpisodesPostsTheFeedURL() async throws {
        let fixture = try feedFixture()
        let stub = StubServer { _ in StubResponse(status: 200, body: fixture) }
        let response = try await makeClient(stub).send(
            PodcastEpisodeManagementEndpoints.feedEpisodes(rssFeed: "https://example.com/feed.xml"))
        #expect(response.episodes.count == 3)
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/abs/api/podcasts/feed")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let object = try #require(try body(request) as? [String: Any])
        #expect(object.count == 1)
        #expect(object["rssFeed"] as? String == "https://example.com/feed.xml")
    }

    /// The server's parse at v2.26.0: blank strings read as missing, the enclosure URL is trimmed,
    /// and an episode without one is skipped.
    @Test func feedEpisodesDecodeTheServerShape() throws {
        let response = try JSONDecoder().decode(RSSFeedEpisodesResponse.self, from: try feedFixture())
        #expect(
            response.episodes.map(\.enclosureURL) == [
                "https://example.com/ep1.mp3", "https://example.com/ep3.mp3", "https://example.com/bonus.mp3",
            ])
        let first = try #require(response.episodes.first)
        #expect(first.title == "Episode One")
        #expect(first.subtitle == "Where it starts")
        #expect(first.episode == "1")
        #expect(first.publishedAt == 1_699_913_600_000)
        let third = response.episodes[1]
        #expect(third.subtitle == nil)
        #expect(third.episode == "3")
        let undated = response.episodes[2]
        #expect(undated.publishedAt == nil)
        #expect(undated.episode == nil)
    }

    @Test func feedWithoutEpisodesReadsAsEmpty() throws {
        for json in [#"{"podcast":{"metadata":{}}}"#, #"{}"#, #"{"podcast":{"episodes":null}}"#] {
            let response = try JSONDecoder().decode(RSSFeedEpisodesResponse.self, from: Data(json.utf8))
            #expect(response.episodes.isEmpty)
        }
    }

    /// The download sends each episode back exactly as the feed lookup returned it, untrimmed
    /// URL, chapters and nulls included, as legacy did.
    @Test func downloadEpisodesSendsTheFeedEpisodesUnchanged() async throws {
        let fixture = try feedFixture()
        let episodes = try JSONDecoder().decode(RSSFeedEpisodesResponse.self, from: fixture).episodes
        let stub = StubServer { _ in .text("OK", status: 200) }
        _ = try await makeClient(stub).send(
            PodcastEpisodeManagementEndpoints.downloadEpisodes(podcastID: "li 1/x", episodes: Array(episodes.prefix(2)))
        )
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString.hasSuffix("/abs/api/podcasts/li%201%2Fx/download-episodes") == true)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let sent = try #require(try body(request) as? NSArray)
        let feed = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        let original = try #require((feed["podcast"] as? [String: Any])?["episodes"] as? NSArray)
        #expect(sent == NSArray(array: Array(original.prefix(2))))
    }

    @Test func clearDownloadQueueRequest() async throws {
        let stub = StubServer { _ in .text("OK", status: 200) }
        _ = try await makeClient(stub).send(PodcastEpisodeManagementEndpoints.clearDownloadQueue(podcastID: "li-1"))
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path() == "/abs/api/podcasts/li-1/clear-queue")
        #expect(request.httpBody == nil)
    }

    @Test(arguments: [false, true])
    func removeEpisodeRequest(deleteFile: Bool) async throws {
        let stub = StubServer { _ in .json(#"{"id":"li-1","media":{}}"#) }
        _ = try await makeClient(stub).send(
            PodcastEpisodeManagementEndpoints.removeEpisode(
                podcastID: "li-1", episodeID: "ep/1", deleteFile: deleteFile))
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString.contains("/abs/api/podcasts/li-1/episode/ep%2F1") == true)
        #expect(request.url?.query() == (deleteFile ? "hard=1" : nil))
        #expect(request.httpBody == nil)
    }

    /// Each request carries URLs or changes the server, so none follows a redirect off the origin.
    @Test func everyEndpointStaysOnOrigin() {
        #expect(PodcastEpisodeManagementEndpoints.feedEpisodes(rssFeed: "x").staysOnOrigin)
        #expect(PodcastEpisodeManagementEndpoints.downloadEpisodes(podcastID: "p", episodes: []).staysOnOrigin)
        #expect(PodcastEpisodeManagementEndpoints.clearDownloadQueue(podcastID: "p").staysOnOrigin)
        #expect(
            PodcastEpisodeManagementEndpoints.removeEpisode(podcastID: "p", episodeID: "e", deleteFile: true)
                .staysOnOrigin)
        #expect(
            PodcastEpisodeManagementEndpoints.removeEpisode(podcastID: "p", episodeID: "e", deleteFile: false)
                .staysOnOrigin)
    }

    /// A clear or removal redirected to another host is refused before that host is contacted, so
    /// its 2xx can't read as success.
    @Test(arguments: [307, 308])
    func crossOriginRedirectOfAMutationIsRefused(status: Int) async throws {
        let other = StubServer { _ in .text("OK", status: 200) }
        let origin = StubServer { _ in .redirect(to: "https://\(other.host)/x", status: status) }
        let client = try makeClient(origin)
        await #expect(throws: APIError.redirectRefused(status: status)) {
            try await client.send(PodcastEpisodeManagementEndpoints.clearDownloadQueue(podcastID: "li-1"))
        }
        await #expect(throws: APIError.redirectRefused(status: status)) {
            try await client.send(
                PodcastEpisodeManagementEndpoints.removeEpisode(podcastID: "li-1", episodeID: "ep-1", deleteFile: true))
        }
        #expect(other.requests.isEmpty)
        #expect(origin.requests.count == 2)
    }

    @Test func rawJSONRoundTrips() throws {
        let json = #"{"a":[1,2.5,true,null,"s"],"b":{"c":false},"d":1701123200000}"#
        let value = try JSONDecoder().decode(RawJSONValue.self, from: Data(json.utf8))
        #expect(value["a"] == .array([.number(1), .number(2.5), .bool(true), .null, .string("s")]))
        let encoded = try JSONEncoder().encode(value)
        let reread = try JSONSerialization.jsonObject(with: encoded) as? NSDictionary
        let original = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
        #expect(reread == original)
        #expect(String(decoding: encoded, as: UTF8.self).contains("1701123200000"))
    }
}
