import ABSCore
import Foundation
import Synchronization
import Testing

@testable import ABSAPI
@testable import ABSPlayback

private struct StaticTokens: TokenProvider {
    let value: ABSAPI.AuthTokens?

    func tokens() async -> ABSAPI.AuthTokens? { value }
    func replaceTokens(expected: ABSAPI.AuthTokens, with new: ABSAPI.AuthTokens) async -> Bool { false }
    func expireSession(ifCurrent rejected: ABSAPI.AuthTokens) async -> Bool { false }
}

private struct StaticDevice: DeviceIdentifying {
    func deviceIdentifier() async -> String { "device" }
}

struct APIPlaybackSessionServiceTests {
    private func service(
        version: ServerVersion = ServerVersion(2, 26, 2), customHeaders: [String: String] = [:],
        tokens: ABSAPI.AuthTokens? = ABSAPI.AuthTokens(accessToken: "a+b", refreshToken: "r")
    ) throws -> APIPlaybackSessionService {
        let configuration = try APIClientConfiguration(
            baseURL: try #require(URL(string: "https://abs.example/abs")), customHeaders: customHeaders)
        return APIPlaybackSessionService(
            serverConnectionID: UUID(),
            client: APIClient(configuration: configuration, tokenProvider: StaticTokens(value: tokens)),
            features: ServerFeatures(version: version), deviceIdentifiers: StaticDevice())
    }

    /// A service whose stored access token is `accessToken` (the clock reads ``pinnedNow``), on a
    /// server that answers the token refresh with `refresh`.
    private func refreshingService(
        accessToken: String, refresh: StubRefresh
    ) async throws -> (service: APIPlaybackSessionService, tokens: RefreshingTokens, server: StubRefreshServer) {
        let server = StubRefreshServer(refresh)
        let tokens = RefreshingTokens(ABSAPI.AuthTokens(accessToken: accessToken, refreshToken: "r"))
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: server.baseURL), tokenProvider: tokens,
            sessionConfiguration: server.sessionConfiguration())
        await client.setNow { pinnedNow }
        let service = APIPlaybackSessionService(
            serverConnectionID: UUID(), client: client, features: ServerFeatures(version: ServerVersion(2, 26, 2)),
            deviceIdentifiers: StaticDevice())
        return (service, tokens, server)
    }

    private func episodeSession(index: Int?) -> PlaybackSession {
        PlaybackSession(
            id: "sess", libraryItemId: "li-9", episodeId: "ep-1", mediaType: .podcast, duration: 1200,
            playMethod: .directPlay,
            audioTracks: [
                AudioTrack(
                    index: index, startOffset: 0, duration: 1200, contentUrl: "/api/items/li-9/file/77",
                    mimeType: "audio/mpeg")
            ])
    }

    @Test func sessionTracksUseTheirURLs() async throws {
        let stream = try await service(version: ServerVersion(2, 37, 0)).resolveStream(for: episodeSession(index: 1))
        #expect(stream.urls.map(\.absoluteString) == ["https://abs.example/abs/public/session/sess/track/1"])
        #expect(stream.plan.kind == .directPlay)
    }

    @Test func tokenFallbackAddsTheAccessToken() async throws {
        let stream = try await service().resolveStream(for: episodeSession(index: nil))
        #expect(stream.urls.map(\.absoluteString) == ["https://abs.example/abs/api/items/li-9/file/77?token=a%2Bb"])
    }

    @Test func tokenFallbackWithoutTokensFails() async throws {
        // No stored tokens: the client throws `APIError.notAuthenticated`.
        let service = try service(tokens: nil)
        await #expect(throws: StreamResolutionError.missingAccessToken) {
            try await service.resolveStream(for: episodeSession(index: nil))
        }
    }

    @Test func tokenFallbackRefreshesAnExpiringToken() async throws {
        let stale = jwt(expiringAt: pinnedNow.addingTimeInterval(60))
        let fresh = jwt(expiringAt: pinnedNow.addingTimeInterval(3600))
        let (service, tokens, server) = try await refreshingService(accessToken: stale, refresh: .issuing(fresh))

        let stream = try await service.resolveStream(for: episodeSession(index: nil))

        #expect(stream.urls.map(\.absoluteString) == ["\(server.baseURL)/api/items/li-9/file/77?token=\(fresh)"])
        #expect(server.requests.map { $0.url?.path() } == ["/abs/auth/refresh"])
        #expect(tokens.current?.accessToken == fresh)
    }

    @Test func tokenFallbackFailsWhenTheServerRejectsTheRefreshToken() async throws {
        // The refresh answers 401: the client throws `APIError.sessionExpired` and clears the tokens.
        let (service, tokens, server) = try await refreshingService(
            accessToken: jwt(expiringAt: pinnedNow.addingTimeInterval(60)), refresh: .rejected)

        await #expect(throws: StreamResolutionError.missingAccessToken) {
            try await service.resolveStream(for: episodeSession(index: nil))
        }
        #expect(server.requests.count == 1)
        #expect(tokens.current == nil)
    }

    @Test func tokenFallbackPropagatesOtherRefreshFailures() async throws {
        let (service, _, _) = try await refreshingService(
            accessToken: jwt(expiringAt: pinnedNow.addingTimeInterval(-10)), refresh: .badGateway)

        await #expect(throws: APIError.http(status: 502, message: "Bad gateway")) {
            try await service.resolveStream(for: episodeSession(index: nil))
        }
    }

    @Test func tokenFallbackPropagatesCancellation() async throws {
        let fresh = jwt(expiringAt: pinnedNow.addingTimeInterval(3600))
        let (service, _, _) = try await refreshingService(
            accessToken: jwt(expiringAt: pinnedNow.addingTimeInterval(60)), refresh: .issuing(fresh))
        let session = episodeSession(index: nil)

        // Resolves only once cancelled, so the token request always sees a cancelled caller.
        let resolving = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await service.resolveStream(for: session)
        }
        resolving.cancel()

        await #expect(throws: CancellationError.self) { try await resolving.value }
    }

    @Test func customHeadersGetAHeaderTransport() async throws {
        let service = try service(version: ServerVersion(2, 37, 0), customHeaders: ["X-Proxy": "1"])
        let stream = try await service.resolveStream(for: episodeSession(index: 1))

        #expect(stream.plan.transport == .customHeaderResourceLoader)
        #expect(stream.transport != nil)
        #expect(stream.urls.map(\.absoluteString) == ["https://abs.example/abs/public/session/sess/track/1"])
    }

    @Test func noCustomHeadersNoTransport() async throws {
        let stream = try await service(version: ServerVersion(2, 37, 0)).resolveStream(for: episodeSession(index: 1))
        #expect(stream.transport == nil)
    }

    @Test func transcodeWithCustomHeadersStaysUnsupported() async throws {
        let service = try service(version: ServerVersion(2, 37, 0), customHeaders: ["X-Proxy": "1"])
        let session = PlaybackSession(
            id: "sess", libraryItemId: "li", mediaType: .book, playMethod: .transcode,
            audioTracks: [AudioTrack(index: 1, startOffset: 0, duration: 60, contentUrl: "/hls/sess/output.m3u8")])
        await #expect(throws: StreamResolutionError.resolution(.transcodeUnavailableWithCustomHeaders)) {
            try await service.resolveStream(for: session)
        }
    }

    /// The live service's transport carries the connection's headers end to end.
    @Test func headerTransportSendsTheConnectionHeaders() async throws {
        let host = StreamStubProtocol.register(.init(body: Data(repeating: 7, count: 64)))
        let configuration = try APIClientConfiguration(
            baseURL: try #require(URL(string: "https://\(host)")), customHeaders: ["X-Proxy": "token"])
        let service = APIPlaybackSessionService(
            serverConnectionID: UUID(),
            client: APIClient(
                configuration: configuration,
                tokenProvider: StaticTokens(value: ABSAPI.AuthTokens(accessToken: "a", refreshToken: "r"))),
            features: ServerFeatures(version: ServerVersion(2, 37, 0)), deviceIdentifiers: StaticDevice(),
            streamingConfiguration: { StreamStubProtocol.configuration() })
        let stream = try await service.resolveStream(for: episodeSession(index: 1))
        let transport = try #require(stream.transport)
        let request = RecordingLoadingRequest(range: RequestedRange(offset: 0, length: 8))
        let loaderURL = HeaderStreamingTransport.loaderURL(for: try #require(stream.urls.first))
        // Registers the track, as the engine does.
        _ = transport.makeAsset(url: try #require(stream.urls.first), mimeType: nil, networkAccess: nil)
        transport.loader.queue.async { transport.loader.start(request, loaderURL: loaderURL) }
        await request.finished()

        #expect(request.error == nil)
        #expect(request.data == Data(repeating: 7, count: 8))
        let sent = try #require(StreamStubProtocol.requests(host).first)
        #expect(sent.url?.path() == "/public/session/sess/track/1")
        #expect(sent.value(forHTTPHeaderField: "X-Proxy") == "token")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func resolutionErrorsAreWrapped() async throws {
        let service = try service()
        let session = PlaybackSession(id: "sess", libraryItemId: "li", mediaType: .book, playMethod: .directPlay)
        await #expect(throws: StreamResolutionError.resolution(.noTracks)) {
            try await service.resolveStream(for: session)
        }
    }
}

/// The time the clocks of the clients under test read.
private let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)

/// An unsigned JWT-shaped token that expires at `date`, so the client can tell when to refresh it.
private func jwt(expiringAt date: Date) -> String {
    func segment(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return segment(#"{"alg":"HS256","typ":"JWT"}"#) + "."
        + segment(#"{"userId":"user-1","exp":\#(Int(date.timeIntervalSince1970))}"#) + ".signature"
}

/// A ``TokenProvider`` that applies refreshes and session expiry, as the Keychain-backed one does.
private final class RefreshingTokens: TokenProvider {
    private let stored: Mutex<ABSAPI.AuthTokens?>

    init(_ tokens: ABSAPI.AuthTokens?) {
        stored = Mutex(tokens)
    }

    var current: ABSAPI.AuthTokens? { stored.withLock { $0 } }

    func tokens() async -> ABSAPI.AuthTokens? { current }

    func replaceTokens(expected: ABSAPI.AuthTokens, with new: ABSAPI.AuthTokens) async -> Bool {
        stored.withLock { tokens in
            guard tokens == expected else { return false }
            tokens = new
            return true
        }
    }

    func expireSession(ifCurrent rejected: ABSAPI.AuthTokens) async -> Bool {
        stored.withLock { tokens in
            guard tokens == rejected else { return false }
            tokens = nil
            return true
        }
    }
}

/// How the stub server answers `POST /auth/refresh`.
private struct StubRefresh: Sendable {
    var status: Int
    var body: String
    var contentType = "application/json"

    /// The refresh succeeds and issues `accessToken`.
    static func issuing(_ accessToken: String) -> StubRefresh {
        StubRefresh(status: 200, body: #"{"user":{"accessToken":"\#(accessToken)","refreshToken":"r2"}}"#)
    }

    /// The server rejects the refresh token.
    static let rejected = StubRefresh(status: 401, body: "Invalid refresh token", contentType: "text/plain")

    static let badGateway = StubRefresh(status: 502, body: "Bad gateway", contentType: "text/plain")
}

/// Answers every request to a registered host with that host's ``StubRefresh`` and records the
/// requests. Hosts are unique, so tests running in parallel never share a route.
private final class StubRefreshProtocol: URLProtocol {
    struct Route {
        var refresh: StubRefresh
        var requests: [URLRequest] = []
    }

    static let routes = Mutex<[String: Route]>([:])

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return routes.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return fail() }
        let refresh = Self.routes.withLock { routes -> StubRefresh? in
            routes[host]?.requests.append(request)
            return routes[host]?.refresh
        }
        guard let refresh,
            let response = HTTPURLResponse(
                url: url, statusCode: refresh.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": refresh.contentType])
        else { return fail() }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(refresh.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func fail() {
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }
}

/// A server on a unique host, hosted under the subpath `/abs`, whose refresh endpoint answers with
/// `refresh`.
private struct StubRefreshServer {
    let host = "\(UUID().uuidString.lowercased()).playback.test"

    init(_ refresh: StubRefresh) {
        StubRefreshProtocol.routes.withLock { $0[host] = StubRefreshProtocol.Route(refresh: refresh) }
    }

    var baseURL: URL { URL(string: "https://\(host)/abs")! }

    var requests: [URLRequest] { StubRefreshProtocol.routes.withLock { $0[host]?.requests ?? [] } }

    func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.absConnection()
        configuration.protocolClasses = [StubRefreshProtocol.self]
        return configuration
    }
}
