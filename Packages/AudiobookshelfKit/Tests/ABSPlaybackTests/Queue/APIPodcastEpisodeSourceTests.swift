import ABSCore
import ABSData
import Foundation
import Synchronization
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// Answers requests for its hosts with JSON bodies by URL path, and records the paths asked for.
private final class JSONStubProtocol: URLProtocol {
    private static let routes = Mutex<[String: (bodies: [String: String], requested: [String])]>([:])

    static func register(host: String, bodies: [String: String]) {
        routes.withLock { $0[host] = (bodies, []) }
    }

    static func requested(host: String) -> [String] {
        routes.withLock { $0[host]?.requested ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return routes.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return }
        let body = Self.routes.withLock { routes -> String? in
            routes[host]?.requested.append(url.path())
            return routes[host]?.bodies[url.path()]
        }
        let response = HTTPURLResponse(
            url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: Data((body ?? "").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct NoTokens: TokenProvider {
    func tokens() async -> ABSAPI.AuthTokens? { ABSAPI.AuthTokens(accessToken: "a", refreshToken: "r") }
    func replaceTokens(expected: ABSAPI.AuthTokens, with new: ABSAPI.AuthTokens) async -> Bool { false }
    func expireSession(ifCurrent rejected: ABSAPI.AuthTokens) async -> Bool { false }
}

/// Local progress that records which media were looked up.
private final class RecordingProgress: LocalProgressReading {
    private let store: LocalProgressStore
    private let lookups = Mutex<[String]>([])

    init(_ store: LocalProgressStore) {
        self.store = store
    }

    var episodeIDs: [String] { lookups.withLock { $0 } }

    func progress(for key: MediaKey) async throws -> LocalMediaProgressDTO? {
        lookups.withLock { $0.append(key.episodeId ?? "") }
        return try await store.progress(for: key)
    }
}

struct APIPodcastEpisodeSourceTests {
    let connection = UUID()
    let host = "\(UUID().uuidString.lowercased()).stub.test"

    private let item = """
        {"id": "li-1", "libraryId": "lib", "mediaType": "podcast", "isMissing": false, "isInvalid": false,
         "media": {"id": "pod", "metadata": {"title": "Pod", "type": "serial"},
                   "episodes": [{"id": "e1", "publishedAt": 1}, {"id": "e2", "publishedAt": 2},
                                {"id": "e3", "publishedAt": 3}, {"id": "e4", "publishedAt": 4}]}}
        """
    private let me = """
        {"id": "u1", "username": "me", "mediaProgress": [
            {"id": "p1", "libraryItemId": "li-1", "episodeId": "e1", "isFinished": true},
            {"id": "p2", "libraryItemId": "li-1", "episodeId": "e2", "isFinished": true},
            {"id": "p9", "libraryItemId": "other", "episodeId": "e3", "isFinished": true}]}
        """

    private func source(localProgress: (any LocalProgressReading)?) throws -> APIPodcastEpisodeSource {
        JSONStubProtocol.register(host: host, bodies: ["/abs/api/items/li-1": item, "/abs/api/me": me])
        let configuration = URLSessionConfiguration.absConnection()
        configuration.protocolClasses = [JSONStubProtocol.self]
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: try #require(URL(string: "https://\(host)/abs"))),
            tokenProvider: NoTokens(), sessionConfiguration: configuration)
        return APIPodcastEpisodeSource(client: client, serverConnectionID: connection, localProgress: localProgress)
    }

    private func key(_ episode: String) -> MediaKey {
        MediaKey(serverConnectionID: connection, libraryItemId: "li-1", episodeId: episode)
    }

    @Test func listingCombinesTheItemAndTheUsersProgress() async throws {
        let listing = try await source(localProgress: nil).listing(podcastItemID: "li-1")

        #expect(listing.isSerial)
        #expect(listing.episodes.map(\.id) == ["e1", "e2", "e3", "e4"])
        #expect(listing.finishedEpisodeIDs == ["e1", "e2"])
        #expect(Set(JSONStubProtocol.requested(host: host)) == ["/abs/api/items/li-1", "/abs/api/me"])
    }

    @Test func unsyncedLocalFinishedChangesOverrideTheServer() async throws {
        let store = try LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
        // Finished and un-finished on this device, not synced yet.
        try await store.recordEdit(ProgressEdit(isFinished: true), for: key("e3"), now: .now)
        try await store.recordEdit(ProgressEdit(isFinished: false), for: key("e2"), now: .now)
        // Only audio progress changed locally: the server's finished state stands.
        try await store.recordEdit(
            ProgressEdit(audio: .init(currentTime: 5, duration: 100, progress: 0.05)), for: key("e1"), now: .now)

        let listing = try await source(localProgress: store).listing(podcastItemID: "li-1")

        #expect(listing.finishedEpisodeIDs == ["e1", "e3"])
        #expect(listing.nextUnfinished(after: "e1")?.id == "e2")
    }

    @Test func localProgressIsReadOnlyUntilTwoEpisodesAreUnfinished() async throws {
        let store = try LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
        // Server: e1 and e2 finished. This device un-finished e1, not synced yet.
        try await store.recordEdit(ProgressEdit(isFinished: false), for: key("e1"), now: .now)
        let progress = RecordingProgress(store)

        let listing = try await source(localProgress: progress).listing(podcastItemID: "li-1")

        // Play order e1, e2, e3, e4: e1 and e3 are the first two unfinished, so e4 isn't read.
        #expect(progress.episodeIDs == ["e1", "e2", "e3"])
        #expect(listing.nextUnfinished(after: "e1")?.id == "e3")
        #expect(listing.nextUnfinished(after: "e3")?.id == "e1")
        #expect(listing.nextUnfinished(after: "e4")?.id == "e1")
        #expect(listing.nextUnfinished(after: "e2")?.id == "e1")
    }
}
