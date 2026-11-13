import ABSCore
import Foundation
import Synchronization
import Testing

@testable import ABSAPI
@testable import ABSPlayback

private struct NoTokens: TokenProvider {
    func tokens() async -> ABSAPI.AuthTokens? { ABSAPI.AuthTokens(accessToken: "a", refreshToken: "r") }
    func replaceTokens(expected: ABSAPI.AuthTokens, with new: ABSAPI.AuthTokens) async -> Bool { false }
    func expireSession(ifCurrent rejected: ABSAPI.AuthTokens) async -> Bool { false }
}

private struct FixedDevice: DeviceIdentifying {
    func deviceIdentifier() async -> String { "device" }
}

private func client() throws -> APIClient {
    APIClient(
        configuration: try APIClientConfiguration(baseURL: try #require(URL(string: "https://abs.example"))),
        tokenProvider: NoTokens())
}

/// Answers every request to its hosts with an empty response, 200 unless the host has another
/// status, and records the paths, by host.
private final class RecordingServerProtocol: URLProtocol {
    static let paths = Mutex<[String: [String]]>([:])
    static let statuses = Mutex<[String: Int]>([:])

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return paths.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
            let response = HTTPURLResponse(
                url: url, statusCode: Self.statuses.withLock { $0[host] ?? 200 }, httpVersion: nil,
                headerFields: nil)
        else { return }
        Self.paths.withLock { $0[host, default: []].append(url.path()) }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// One account's server on a unique host, answering every request with `status`.
private struct RecordingServer {
    let host = "\(UUID().uuidString.lowercased()).scope.test"

    init(status: Int = 200) {
        RecordingServerProtocol.paths.withLock { $0[host] = [] }
        RecordingServerProtocol.statuses.withLock { $0[host] = status }
    }

    var paths: [String] { RecordingServerProtocol.paths.withLock { $0[host] ?? [] } }

    func client(tokens: any TokenProvider = NoTokens()) throws -> APIClient {
        let configuration = URLSessionConfiguration.absConnection()
        configuration.protocolClasses = [RecordingServerProtocol.self]
        return APIClient(
            configuration: try APIClientConfiguration(baseURL: try #require(URL(string: "https://\(host)"))),
            tokenProvider: tokens, sessionConfiguration: configuration)
    }
}

/// Tokens whose first request is held, after it has read the services' snapshot, until released.
private actor HeldTokens: TokenProvider {
    private var entered: CheckedContinuation<Void, Never>?
    private var held: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var isReleased = false

    func tokens() async -> ABSAPI.AuthTokens? {
        if !hasEntered {
            hasEntered = true
            entered?.resume()
            entered = nil
            if !isReleased { await withCheckedContinuation { held = $0 } }
        }
        return ABSAPI.AuthTokens(accessToken: "a", refreshToken: "r")
    }

    func replaceTokens(expected: ABSAPI.AuthTokens, with new: ABSAPI.AuthTokens) async -> Bool { false }
    func expireSession(ifCurrent rejected: ABSAPI.AuthTokens) async -> Bool { false }

    func waitUntilEntered() async {
        if !hasEntered { await withCheckedContinuation { entered = $0 } }
    }

    func release() {
        isReleased = true
        held?.resume()
        held = nil
    }
}

private let features = ServerFeatures(version: ServerVersion(2, 37, 2))

/// A session whose track has a session URL: resolving it needs features and a client, not the
/// network.
private let session = PlaybackSession(
    id: "sess", libraryItemId: "li", mediaType: .book, duration: 60, playMethod: .directPlay,
    audioTracks: [
        AudioTrack(index: 1, startOffset: 0, duration: 60, contentUrl: "/api/items/li/file/1", mimeType: "audio/mpeg")
    ])

private func services(client: APIClient?, features: ServerFeatures?, id: UUID = UUID()) -> AccountPlaybackServices {
    AccountPlaybackServices(
        serverConnectionID: id, client: client, features: features, deviceIdentifiers: FixedDevice())
}

struct AccountPlaybackServicesTests {
    @Test func withoutClientOrFeaturesStartSessionThrowsNotAuthenticated() async throws {
        let services = services(client: nil, features: nil)

        #expect(!services.canStartSessions)
        await #expect(throws: APIError.notAuthenticated) {
            try await services.startSession(itemID: "li", episodeID: nil)
        }
        await #expect(throws: APIError.notAuthenticated) {
            try await services.mediaProgress(itemID: "li", episodeID: nil)
        }
        await #expect(throws: APIError.notAuthenticated) { try await services.closeSession(id: "s", report: nil) }
        await #expect(throws: APIError.notAuthenticated) {
            try await services.fetchProgress(itemID: "li", episodeID: nil)
        }
        await #expect(throws: APIError.notAuthenticated) {
            try await services.updateProgress(itemID: "li", episodeID: nil, .finished(true))
        }
        await #expect(throws: StreamResolutionError.missingAccessToken) {
            try await services.resolveStream(for: session)
        }
    }

    @Test func featuresWithoutAClientCannotStartSessions() async throws {
        let services = services(client: nil, features: features)

        #expect(!services.canStartSessions)
        await #expect(throws: APIError.notAuthenticated) {
            try await services.startSession(itemID: "li", episodeID: nil)
        }
        await #expect(throws: StreamResolutionError.missingAccessToken) {
            try await services.resolveStream(for: session)
        }
    }

    /// Features are never invented: a client alone can't start or resolve a session.
    @Test func aClientWithoutFeaturesCannotStartSessions() async throws {
        let services = services(client: try client(), features: nil)

        #expect(!services.canStartSessions)
        await #expect(throws: APIError.notAuthenticated) {
            try await services.startSession(itemID: "li", episodeID: nil)
        }
        await #expect(throws: StreamResolutionError.missingAccessToken) {
            try await services.resolveStream(for: session)
        }
    }

    @Test func updateKeepsTheConnectionIDAndEnablesSessions() async throws {
        let id = UUID()
        let services = services(client: nil, features: nil, id: id)

        services.update(client: try client(), features: features)

        #expect(services.serverConnectionID == id)
        #expect(services.canStartSessions)
        let stream = try await services.resolveStream(for: session)
        #expect(stream.urls.map(\.absoluteString) == ["https://abs.example/public/session/sess/track/1"])

        // Going offline again takes it away.
        services.update(client: nil, features: features)
        #expect(!services.canStartSessions)
    }

    /// The negative control for "an expired account uses no network": nothing brings it back.
    @Test func invalidateIsPermanent() async throws {
        let services = services(client: try client(), features: features)
        #expect(services.canStartSessions)

        services.invalidate()
        services.update(client: try client(), features: features)

        #expect(!services.canStartSessions)
        await #expect(throws: APIError.notAuthenticated) {
            try await services.startSession(itemID: "li", episodeID: nil)
        }
        await #expect(throws: APIError.notAuthenticated) { try await services.closeSession(id: "s", report: nil) }
        let report = try #require(PlaybackSyncReport(currentTime: 1, timeListened: 1, duration: 60))
        await #expect(throws: APIError.notAuthenticated) { try await services.syncSession(id: "s", report: report) }
        await #expect(throws: StreamResolutionError.missingAccessToken) {
            try await services.resolveStream(for: session)
        }
    }

    /// Each call captures its client and features once: a request in flight across a reconnect
    /// finishes on the client it started with, and the next one uses the new client.
    @Test func anInFlightRequestStaysOnItsClientAcrossAReconnect() async throws {
        let old = RecordingServer()
        let new = RecordingServer()
        let held = HeldTokens()
        let services = services(client: try old.client(tokens: held), features: features)
        let report = try #require(PlaybackSyncReport(currentTime: 1, timeListened: 1, duration: 60))

        let inFlight = Task { try await services.syncSession(id: "s1", report: report) }
        await held.waitUntilEntered()
        services.update(client: try new.client(), features: features)
        await held.release()
        try await inFlight.value
        try await services.syncSession(id: "s2", report: report)

        #expect(old.paths == ["/api/session/s1/sync"])
        #expect(new.paths == ["/api/session/s2/sync"])
    }

    /// Invalidation rejects new calls; it doesn't claim to retract a request already under way.
    @Test func invalidationRejectsNewCallsButNotOneInFlight() async throws {
        let server = RecordingServer()
        let held = HeldTokens()
        let services = services(client: try server.client(tokens: held), features: features)
        let report = try #require(PlaybackSyncReport(currentTime: 1, timeListened: 1, duration: 60))

        let inFlight = Task { try await services.syncSession(id: "s1", report: report) }
        await held.waitUntilEntered()
        services.invalidate()
        await held.release()
        try await inFlight.value

        await #expect(throws: APIError.notAuthenticated) { try await services.syncSession(id: "s2", report: report) }
        #expect(server.paths == ["/api/session/s1/sync"])
    }

    /// A `/sync` 404 (the server no longer has the session) tells the handler which session, and
    /// still throws, so the syncer's own 404 handling runs (#184).
    @Test func aSyncNotFoundReportsTheGoneSessionAndRethrows() async throws {
        let server = RecordingServer(status: 404)
        let services = services(client: try server.client(), features: features)
        let gone = GoneSessions()
        services.setSessionGoneHandler { gone.record($0) }
        let report = try #require(PlaybackSyncReport(currentTime: 1, timeListened: 1, duration: 60))

        await #expect(throws: APIError.notFound) { try await services.syncSession(id: "s1", report: report) }

        #expect(gone.ids == ["s1"])
        #expect(server.paths == ["/api/session/s1/sync"])
    }

    /// The negative control: a sync the server accepts, or one that fails otherwise, reports nothing.
    @Test func otherSyncAnswersReportNoGoneSession() async throws {
        let gone = GoneSessions()
        let report = try #require(PlaybackSyncReport(currentTime: 1, timeListened: 1, duration: 60))
        let accepted = services(client: try RecordingServer().client(), features: features)
        accepted.setSessionGoneHandler { gone.record($0) }
        let failing = services(client: try RecordingServer(status: 500).client(), features: features)
        failing.setSessionGoneHandler { gone.record($0) }

        try await accepted.syncSession(id: "s1", report: report)
        await #expect(throws: (any Error).self) { try await failing.syncSession(id: "s2", report: report) }

        #expect(gone.ids.isEmpty)
    }

    /// Invalidation drops the handler, and a later one isn't taken.
    @Test func invalidationDropsTheSessionGoneHandler() async throws {
        let services = services(client: try client(), features: features)
        services.setSessionGoneHandler { _ in }
        #expect(services.hasSessionGoneHandler)

        services.invalidate()
        #expect(!services.hasSessionGoneHandler)
        services.setSessionGoneHandler { _ in }
        #expect(!services.hasSessionGoneHandler)
    }
}

/// The session IDs a session-gone handler heard.
private final class GoneSessions: Sendable {
    private let state = Mutex<[String]>([])

    var ids: [String] { state.withLock { $0 } }
    func record(_ id: String) { state.withLock { $0.append(id) } }
}
