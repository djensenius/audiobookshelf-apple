import ABSCore
import ABSData
import Foundation
import Synchronization
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// Answers a serial podcast `P` with episodes `e1`–`e3`, nothing finished, on its hosts: a
/// session for each episode's play, the item and `GET /api/me`; 404 otherwise. Records the paths
/// by host.
private final class PodcastServerProtocol: URLProtocol {
    static let paths = Mutex<[String: [String]]>([:])

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return paths.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return }
        let path = url.path()
        Self.paths.withLock { $0[host, default: []].append(path) }
        let body = Self.body(for: path, isServing: host.hasPrefix("new-"))
        guard
            let response = HTTPURLResponse(
                url: url, statusCode: body == nil ? 404 : 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(for path: String, isServing: Bool) -> Data? {
        guard isServing else { return nil }
        let encoder = JSONEncoder()
        if path.hasPrefix("/api/items/P/play/") {
            let episode = String(path.dropFirst("/api/items/P/play/".count))
            return try? encoder.encode(
                PlaybackSession(
                    id: "sess-\(episode)", libraryItemId: "P", episodeId: episode, mediaType: .podcast, duration: 60,
                    playMethod: .directPlay,
                    audioTracks: [
                        AudioTrack(
                            index: 1, startOffset: 0, duration: 60, contentUrl: "/api/items/P/file/1",
                            mimeType: "audio/mpeg")
                    ]))
        }
        switch path {
        case "/api/items/P":
            let episodes = ["e1", "e2", "e3"].enumerated().map {
                PodcastEpisode(id: $0.element, publishedAt: $0.offset)
            }
            return try? encoder.encode(
                LibraryItem(
                    id: "P", libraryId: "lib", mediaType: .podcast,
                    media: .podcast(
                        Podcast(
                            id: "pod", metadata: PodcastMetadata(title: "Pod", type: "serial"), episodes: episodes))))
        case "/api/me": return Data(#"{"mediaProgress":[]}"#.utf8)
        default: return nil
        }
    }

    /// A client of a new host; only one whose name starts with `new-` answers.
    static func client(serving: Bool) throws -> (client: APIClient, host: String) {
        let host = "\(serving ? "new" : "old")-\(UUID().uuidString.lowercased()).podcast.test"
        paths.withLock { $0[host] = [] }
        let configuration = URLSessionConfiguration.absConnection()
        configuration.protocolClasses = [PodcastServerProtocol.self]
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: try #require(URL(string: "https://\(host)"))),
            tokenProvider: PodcastTokens(), sessionConfiguration: configuration)
        return (client, host)
    }
}

private struct PodcastTokens: TokenProvider {
    func tokens() async -> ABSAPI.AuthTokens? { ABSAPI.AuthTokens(accessToken: "a", refreshToken: "r") }
    func replaceTokens(expected: ABSAPI.AuthTokens, with new: ABSAPI.AuthTokens) async -> Bool { false }
    func expireSession(ifCurrent rejected: ABSAPI.AuthTokens) async -> Bool { false }
}

private struct PodcastDevice: DeviceIdentifying {
    func deviceIdentifier() async -> String { "device" }
}

@MainActor
struct PlaybackScopePodcastTests {
    /// The podcast fallback ``PlaybackScope/make(_:makeNowPlaying:)`` composes: with nothing
    /// queued, an ending episode plays the next unfinished one, honouring a finish the scope's
    /// writer hasn't synced yet, fetched through the client a reconnect swapped in.
    @Test func anEndingEpisodePlaysTheNextUnfinishedThroughTheCurrentClient() async throws {
        let connectionID = UUID()
        let writer = try LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
        _ = try await writer.recordEdit(
            ProgressEdit(isFinished: true),
            for: MediaKey(serverConnectionID: connectionID, libraryItemId: "P", episodeId: "e2"))
        let old = try PodcastServerProtocol.client(serving: false)
        let new = try PodcastServerProtocol.client(serving: true)
        let features = ServerFeatures(version: ServerVersion(2, 37, 2))
        let engine = CoordinatorTestEngine()
        let configuration = PlaybackScope.Configuration(
            connectionID: connectionID, client: old.client, features: features, deviceIdentifiers: PodcastDevice(),
            writer: writer, settings: StubPlaybackSettings(), policy: StubStreamingPolicy(), engine: engine,
            tickInterval: 0.5, lastPlayed: { _ in InMemoryLastPlayedStore() }, queueStore: AdvanceQueueStore())
        let nowPlaying = RecordingNowPlaying()
        let scope = PlaybackScope.make(configuration) { coordinator in
            nowPlaying.coordinator = coordinator
            return nowPlaying
        }
        scope.reconnect(client: new.client, features: features)

        await scope.play(itemID: "P", episodeID: "e1", startTime: nil)
        await scope.advancer?.waitForPreparation()
        engine.finish()
        await scope.coordinator.waitForAutoAdvance()

        #expect(scope.coordinator.mediaKey?.episodeId == "e3")
        #expect(scope.queue?.items.isEmpty == true)
        #expect(PodcastServerProtocol.paths.withLock { $0[old.host] } == [])
        scope.retire(reason: .accountSwitch)
        _ = await scope.finishRetirement()
    }
}
