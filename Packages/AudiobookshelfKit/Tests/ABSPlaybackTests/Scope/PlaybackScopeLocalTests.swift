import ABSCore
import ABSData
import Foundation
import Synchronization
import Testing

@testable import ABSAPI
@testable import ABSData
@testable import ABSPlayback

/// A scope made with ``PlaybackScope/Configuration/downloads`` (#74): a downloaded book `book`
/// on "disk", and a server that streams it and records every request.
@MainActor
private struct LocalScope {
    let connectionID = UUID()
    let host: String
    let writer: LocalProgressStore
    let files = LocalFiles()
    let scope: PlaybackScope

    init(downloaded: Bool = true) throws {
        let items = LocalItems()
        let book = LocalLibraryItemDTO.book(connection: connectionID)
        if downloaded { items.add(book) }
        files.addAll(for: book)
        writer = try LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
        let (client, host) = try LocalServerProtocol.client()
        self.host = host
        var configuration = PlaybackScope.Configuration(
            connectionID: connectionID, client: client, features: ServerFeatures(version: ServerVersion(2, 37, 2)),
            deviceIdentifiers: LocalTestDevice(), writer: writer, settings: StubPlaybackSettings(),
            policy: StubStreamingPolicy(), engine: CoordinatorTestEngine(), tickInterval: 0.5,
            lastPlayed: { _ in InMemoryLastPlayedStore() }, queueStore: AdvanceQueueStore())
        let files = files
        configuration.downloads = LocalDownloadFiles(
            items: items, fileURL: { try LocalFiles.url(for: $0) }, fileExists: { files.exists($0) })
        scope = PlaybackScope.make(configuration) { _ in RecordingNowPlaying() }
    }

    var key: MediaKey { MediaKey(serverConnectionID: connectionID, libraryItemId: "book") }

    /// The paths of the requests the server received.
    var requests: [String] { LocalServerProtocol.requests(host) }

    func finish() async {
        scope.retire(reason: .accountSwitch)
        _ = await scope.finishRetirement()
    }
}

/// The scope plays downloads from their files (ADR 0007, decision 7; #74), and a download missing
/// a file plays only once the user chooses to stream it.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PlaybackScopeLocalTests {
    /// The negative control for the wiring: without it the play asks the server for a session.
    @Test func aDownloadedItemPlaysFromItsFilesWithoutAServerSession() async throws {
        let t = try LocalScope()

        await t.scope.play(itemID: "book", episodeID: nil, startTime: nil)
        #expect(await eventually { t.scope.coordinator.isPlaying })
        let sessionID = try #require(t.scope.coordinator.session?.id)
        #expect(UUID(uuidString: sessionID) != nil)
        // Its tracks are the downloaded files, relative to the downloads root.
        #expect(t.scope.coordinator.session?.audioTracks.first?.contentUrl == "book/1.mp3")

        await t.scope.syncer.flush()

        // Its report is saved for upload, not sent to `/sync`, which has no such session.
        var saved = try await t.writer.session(id: sessionID)
        for _ in 0..<200 where saved == nil {
            try await Task.sleep(for: .milliseconds(10))
            saved = try await t.writer.session(id: sessionID)
        }
        #expect(saved?.key == t.key)
        #expect(!t.requests.contains { $0.hasPrefix("/api/items/book/play") })
        #expect(!t.requests.contains { $0.hasPrefix("/api/session/\(sessionID)") })
        await t.finish()
    }

    /// The negative controls: no silent fallback starts a server session; a "Stream instead"
    /// for media that's no longer in the player does nothing.
    @Test func aDownloadMissingAFileFailsUntilTheUserStreamsIt() async throws {
        let t = try LocalScope()
        t.files.remove("book/2.m4b")

        await t.scope.play(itemID: "book", episodeID: nil, startTime: nil)
        #expect(t.scope.coordinator.error == .downloadFilesMissing(t.key))
        #expect(t.scope.coordinator.session == nil)
        #expect(!t.requests.contains { $0.hasPrefix("/api/items/book/play") })

        await t.scope.streamInsteadOfDownload()

        #expect(await eventually { t.scope.coordinator.isPlaying })
        #expect(t.scope.coordinator.error == nil)
        #expect(t.scope.coordinator.session?.id == "sess-book")
        #expect(t.requests.contains { $0.hasPrefix("/api/items/book/play") })
        await t.finish()
    }

    @Test func streamInsteadWithoutAMissingDownloadDoesNothing() async throws {
        let t = try LocalScope()

        await t.scope.streamInsteadOfDownload()

        #expect(t.scope.coordinator.session == nil)
        #expect(t.requests.isEmpty)
        await t.finish()
    }

    /// The negative control: media without a download streams from the server as before.
    @Test func anItemWithoutADownloadStreams() async throws {
        let t = try LocalScope(downloaded: false)

        await t.scope.play(itemID: "book", episodeID: nil, startTime: nil)

        #expect(await eventually { t.scope.coordinator.isPlaying })
        #expect(t.scope.coordinator.session?.id == "sess-book")
        #expect(t.requests.contains { $0.hasPrefix("/api/items/book/play") })
        await t.finish()
    }
}

/// Answers book `book`'s play with a session, and any other request with an empty 200, on the
/// hosts of its clients, recording each request's path by host.
private final class LocalServerProtocol: URLProtocol {
    private static let log = Mutex<[String: [String]]>([:])

    static func requests(_ host: String) -> [String] { log.withLock { $0[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return log.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
        else { return }
        Self.log.withLock { $0[host, default: []].append(url.path()) }
        let session = PlaybackSession(
            id: "sess-book", libraryItemId: "book", mediaType: .book, displayTitle: "Dune", duration: 250,
            audioTracks: [
                AudioTrack(
                    index: 1, startOffset: 0, duration: 250, contentUrl: "/api/items/book/file/1",
                    mimeType: "audio/mpeg")
            ])
        let isPlay = url.path().hasPrefix("/api/items/book/play")
        let body = isPlay ? (try? JSONEncoder().encode(session)) : nil
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// A client of a host of its own, and that host.
    static func client() throws -> (APIClient, String) {
        let host = "\(UUID().uuidString.lowercased()).local.test"
        log.withLock { $0[host] = [] }
        let configuration = URLSessionConfiguration.absConnection()
        configuration.protocolClasses = [LocalServerProtocol.self]
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: try #require(URL(string: "https://\(host)"))),
            tokenProvider: LocalServerTokens(), sessionConfiguration: configuration)
        return (client, host)
    }
}

private struct LocalServerTokens: TokenProvider {
    func tokens() async -> ABSAPI.AuthTokens? { ABSAPI.AuthTokens(accessToken: "a", refreshToken: "r") }
    func replaceTokens(expected: ABSAPI.AuthTokens, with new: ABSAPI.AuthTokens) async -> Bool { false }
    func expireSession(ifCurrent rejected: ABSAPI.AuthTokens) async -> Bool { false }
}
