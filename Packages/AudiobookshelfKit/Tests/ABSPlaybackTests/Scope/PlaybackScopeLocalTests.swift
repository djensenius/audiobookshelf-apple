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
    let policy = StubStreamingPolicy()
    let engine = CoordinatorTestEngine()
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
            policy: policy, engine: engine, tickInterval: 0.5,
            lastPlayed: { _ in InMemoryLastPlayedStore() }, queueStore: AdvanceQueueStore())
        let files = files
        configuration.downloads = LocalDownloadFiles(
            items: items, fileURL: { try LocalFiles.url(for: $0) }, fileExists: { files.exists($0) })
        scope = PlaybackScope.make(configuration) { _ in RecordingNowPlaying() }
    }

    var key: MediaKey { MediaKey(serverConnectionID: connectionID, libraryItemId: "book") }

    /// Streaming is "never" on the metered path, for every check.
    func denyStreaming() {
        policy.decision = .denied(.cellular)
        policy.currentDecision = .denied(.cellular)
    }

    func playRequests(_ item: String) -> Int {
        requests.filter { $0.hasPrefix("/api/items/\(item)/play") }.count
    }

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

    // MARK: Streaming policy

    /// A download streams nothing, so streaming "never" on a metered path doesn't block it, and
    /// the policy isn't even asked. The negative control: the same item without a download is
    /// blocked.
    @Test(arguments: [true, false])
    func aDownloadPlaysWhereStreamingIsNotAllowed(downloaded: Bool) async throws {
        let t = try LocalScope(downloaded: downloaded)
        t.denyStreaming()

        await t.scope.play(itemID: "book", episodeID: nil, startTime: nil)

        if downloaded {
            #expect(await eventually { t.scope.coordinator.isPlaying })
            #expect(t.scope.coordinator.error == nil)
            #expect(t.policy.checks == 0)
        } else {
            #expect(t.scope.coordinator.error == .streamingNotAllowed(.cellular, key: t.key))
            #expect(t.scope.coordinator.session == nil)
        }
        #expect(t.playRequests("book") == 0)
        await t.finish()
    }

    /// "Ask" on a metered path doesn't prompt for a download either.
    @Test func aDownloadPlaysWithoutAskingOnAMeteredPath() async throws {
        let t = try LocalScope()
        t.policy.decision = .askUser(.cellular)
        t.policy.currentDecision = .askUser(.cellular)

        await t.scope.play(itemID: "book", episodeID: nil, startTime: nil)

        #expect(await eventually { t.scope.coordinator.isPlaying })
        #expect(t.scope.coordinator.error == nil)
        await t.finish()
    }

    /// A download missing a file shows that, not a streaming block: no policy prompt comes first.
    @Test func aDownloadMissingAFileIsReportedBeforeAnyStreamingBlock() async throws {
        let t = try LocalScope()
        t.files.remove("book/2.m4b")
        t.denyStreaming()

        await t.scope.play(itemID: "book", episodeID: nil, startTime: nil)

        #expect(t.scope.coordinator.error == .downloadFilesMissing(t.key))
        await t.finish()
    }

    /// "Stream instead" streams, so the policy decides it: "never" blocks it.
    @Test func streamInsteadIsStillCheckedByTheStreamingPolicy() async throws {
        let t = try LocalScope()
        t.files.remove("book/2.m4b")
        await t.scope.play(itemID: "book", episodeID: nil, startTime: nil)
        #expect(t.scope.coordinator.error == .downloadFilesMissing(t.key))
        t.denyStreaming()

        await t.scope.streamInsteadOfDownload()

        #expect(t.scope.coordinator.error == .streamingNotAllowed(.cellular, key: t.key))
        #expect(t.playRequests("book") == 0)
        await t.finish()
    }

    /// The queue advances from a stream to a downloaded item where streaming has since become
    /// "never": the download plays. The negative control: a streamed next item is blocked.
    @Test(arguments: [true, false])
    func theQueueAdvancesToADownloadWhereStreamingIsNotAllowed(downloaded: Bool) async throws {
        let t = try LocalScope(downloaded: downloaded)
        await t.scope.play(itemID: "A", episodeID: nil, startTime: nil)
        #expect(await eventually { t.scope.coordinator.isPlaying })
        t.scope.editQueue { $0.addToEnd(QueueItem(libraryItemID: "book", title: "Dune")) }
        await t.scope.advancer?.waitForPreparation()
        t.denyStreaming()

        t.engine.finish()
        await t.scope.coordinator.waitForAutoAdvance()

        if downloaded {
            #expect(await eventually { t.scope.coordinator.mediaKey == t.key && t.scope.coordinator.isPlaying })
            #expect(t.scope.coordinator.error == nil)
        } else {
            #expect(t.scope.coordinator.error == .streamingNotAllowed(.cellular, key: t.key))
        }
        #expect(t.playRequests("book") == 0)
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

/// Answers an item's play with a session for it, and any other request with an empty 200, on the
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
        // `/api/items/<id>/play`
        let parts = url.path().split(separator: "/")
        var body: Data?
        if parts.count == 4, parts[0] == "api", parts[1] == "items", parts[3] == "play" {
            let item = String(parts[2])
            let session = PlaybackSession(
                id: "sess-\(item)", libraryItemId: item, mediaType: .book, displayTitle: item, duration: 250,
                audioTracks: [
                    AudioTrack(
                        index: 1, startOffset: 0, duration: 250, contentUrl: "/api/items/\(item)/file/1",
                        mimeType: "audio/mpeg")
                ])
            body = try? JSONEncoder().encode(session)
        }
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
