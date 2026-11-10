import Foundation
import Synchronization
import Testing

@testable import ABSAPI

private let refreshPath = "/abs/auth/refresh"
private let refreshedJSON = #"{"user":{"accessToken":"access-2","refreshToken":"refresh-2"}}"#

/// Answers 200 to `access-2`, 401 to anything else, and `refresh` to `/auth/refresh`.
private func tokenServer(refresh: StubResponse) -> StubServer {
    StubServer { request in
        if request.url?.path() == refreshPath { return refresh }
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer access-2" {
            return .json(#"{"ok":true}"#)
        }
        return .text("Unauthorized", status: 401)
    }
}

private struct OK: Decodable, Sendable, Equatable {
    let ok: Bool
}

private func makeClient(_ server: StubServer, tokens: any TokenProvider) throws -> APIClient {
    APIClient(
        configuration: try APIClientConfiguration(baseURL: server.baseURL),
        tokenProvider: tokens,
        sessionConfiguration: server.sessionConfiguration()
    )
}

@Suite struct APIClientTokenAccessTests {
    @Test func currentAccessTokenMakesNoRequest() async throws {
        let server = tokenServer(refresh: .json(refreshedJSON))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        #expect(await client.currentAccessToken() == "access-1")
        tokens.signOut()
        #expect(await client.currentAccessToken() == nil)
        #expect(server.requests.isEmpty)
    }

    @Test func withoutRejectedTokenReturnsCurrentToken() async throws {
        let server = tokenServer(refresh: .json(refreshedJSON))
        let client = try makeClient(server, tokens: InMemoryTokenProvider())

        #expect(try await client.accessToken(replacing: nil) == "access-1")
        #expect(server.requests.isEmpty)
    }

    @Test func staleRejectedTokenReturnsCurrentTokenWithoutRefreshing() async throws {
        let server = tokenServer(refresh: .json(refreshedJSON))
        let tokens = InMemoryTokenProvider(AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
        let client = try makeClient(server, tokens: tokens)

        #expect(try await client.accessToken(replacing: "access-1") == "access-2")
        #expect(server.requests.isEmpty)
        #expect(tokens.updates.isEmpty)
    }

    @Test func rejectedCurrentTokenRefreshes() async throws {
        let server = tokenServer(refresh: .json(refreshedJSON))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        #expect(try await client.accessToken(replacing: "access-1") == "access-2")
        let refresh = try #require(server.requests(path: refreshPath).first)
        #expect(refresh.value(forHTTPHeaderField: "x-refresh-token") == "refresh-1")
        #expect(server.requests.count == 1)
        #expect(tokens.current == AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
    }

    @Test func concurrentCallersShareOneRefresh() async throws {
        let refreshGate = StubGate()
        let server = tokenServer(refresh: .json(refreshedJSON, gate: refreshGate))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)
        let joins = Checkpoint()
        await client.observeRefreshJoins { joins.pass() }

        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<6 {
                group.addTask { try await client.accessToken(replacing: "access-1") }
            }
            // One caller starts the refresh; the other five wait for it before it finishes.
            await refreshGate.arrived()
            await joins.reached(5)
            refreshGate.open()
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(results == Array(repeating: "access-2", count: 6))
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(tokens.updates.count == 1)
    }

    @Test func joinsRefreshStartedByUnauthorizedRequest() async throws {
        let refreshGate = StubGate()
        let server = tokenServer(refresh: .json(refreshedJSON, gate: refreshGate))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)
        let joins = Checkpoint()
        await client.observeRefreshJoins { joins.pass() }

        async let response = client.send(Endpoint<OK>(.get, "/api/me"))
        await refreshGate.arrived()
        async let token = client.accessToken(replacing: "access-1")
        await joins.reached()
        refreshGate.open()

        #expect(try await token == "access-2")
        #expect(try await response == OK(ok: true))
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(tokens.updates.count == 1)
    }

    @Test func signedOutThrowsNotAuthenticated() async throws {
        let server = tokenServer(refresh: .json(refreshedJSON))
        let client = try makeClient(server, tokens: InMemoryTokenProvider(nil))

        await #expect(throws: APIError.notAuthenticated) {
            try await client.accessToken(replacing: nil)
        }
        await #expect(throws: APIError.notAuthenticated) {
            try await client.accessToken(replacing: "access-1")
        }
        await #expect(throws: APIError.notAuthenticated) {
            try await client.send(Endpoint<OK>(.get, "/api/me"))
        }
        #expect(server.requests.isEmpty)
    }

    @Test func rejectedRefreshExpiresSessionLikeUnauthorizedRequest() async throws {
        let server = tokenServer(refresh: .text("Invalid refresh token", status: 401))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        await #expect(throws: APIError.sessionExpired) {
            try await client.accessToken(replacing: "access-1")
        }
        #expect(tokens.current == nil)
        #expect(tokens.expiredCount == 1)

        let viaRequest = InMemoryTokenProvider()
        let requestClient = try makeClient(server, tokens: viaRequest)
        await #expect(throws: APIError.sessionExpired) {
            try await requestClient.send(Endpoint<OK>(.get, "/api/me"))
        }
        #expect(viaRequest.expiredCount == 1)
    }

    @Test func failedRefreshThrowsSameErrorAsUnauthorizedRequest() async throws {
        let server = tokenServer(refresh: .text("Bad gateway", status: 502))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)
        let expected = APIError.http(status: 502, message: "Bad gateway")

        await #expect(throws: expected) {
            try await client.accessToken(replacing: "access-1")
        }
        await #expect(throws: expected) {
            try await client.send(Endpoint<OK>(.get, "/api/me"))
        }
        #expect(tokens.current == AuthTokens(accessToken: "access-1", refreshToken: "refresh-1"))
        #expect(tokens.expiredCount == 0)
    }
}

private let now = Date(timeIntervalSince1970: 1_700_000_000)
/// The token `/auth/refresh` returns in the expiry tests, valid for an hour.
private let freshToken = makeJWT(expiringAt: now.addingTimeInterval(3600))

/// A client whose clock reads `now`, holding `accessToken`, whose refresh answers `refresh`.
private func makeExpiryClient(
    accessToken: String, refresh: StubResponse = .json(#"{"user":{"accessToken":"\#(freshToken)"}}"#)
) async throws -> (APIClient, StubServer, InMemoryTokenProvider) {
    let server = StubServer { _ in refresh }
    let tokens = InMemoryTokenProvider(AuthTokens(accessToken: accessToken, refreshToken: "refresh-1"))
    let client = try makeClient(server, tokens: tokens)
    await client.setNow { now }
    return (client, server, tokens)
}

@Suite struct APIClientTokenExpiryTests {
    @Test func expiringTokenRefreshesOnceForConcurrentCallers() async throws {
        let refreshGate = StubGate()
        let (client, server, tokens) = try await makeExpiryClient(
            accessToken: makeJWT(expiringAt: now.addingTimeInterval(60)),
            refresh: .json(#"{"user":{"accessToken":"\#(freshToken)"}}"#, gate: refreshGate))
        let joins = Checkpoint()
        await client.observeRefreshJoins { joins.pass() }

        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<4 {
                group.addTask { try await client.accessToken(replacing: nil) }
            }
            await refreshGate.arrived()
            await joins.reached(3)
            refreshGate.open()
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(results == Array(repeating: freshToken, count: 4))
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(server.requests.count == 1)
        #expect(tokens.updates.count == 1)
        // The refreshed token is far from expiry, so the next call doesn't refresh again.
        #expect(try await client.accessToken(replacing: nil) == freshToken)
        #expect(server.requests.count == 1)
    }

    @Test func tokenAtLeewayRefreshesButJustOutsideDoesNot() async throws {
        let atLeeway = makeJWT(expiringAt: now.addingTimeInterval(APIClient.accessTokenExpiryLeeway))
        let (client, server, _) = try await makeExpiryClient(accessToken: atLeeway)
        #expect(try await client.accessToken(replacing: nil) == freshToken)
        #expect(server.requests.count == 1)

        let outside = makeJWT(expiringAt: now.addingTimeInterval(APIClient.accessTokenExpiryLeeway + 1))
        let (farClient, farServer, _) = try await makeExpiryClient(accessToken: outside)
        #expect(try await farClient.accessToken(replacing: nil) == outside)
        #expect(farServer.requests.isEmpty)
    }

    @Test func tokenFarFromExpiryMakesNoRequest() async throws {
        let token = makeJWT(expiringAt: now.addingTimeInterval(3600))
        let (client, server, _) = try await makeExpiryClient(accessToken: token)

        #expect(try await client.accessToken(replacing: nil) == token)
        #expect(server.requests.isEmpty)
    }

    @Test(arguments: ["access-1", "not.a.jwt", makeJWT(claims: #"{"userId":"user-1"}"#)])
    func tokenWithUnknownExpiryMakesNoRequest(token: String) async throws {
        let (client, server, _) = try await makeExpiryClient(accessToken: token)

        #expect(try await client.accessToken(replacing: nil) == token)
        #expect(server.requests.isEmpty)
    }

    @Test(arguments: [
        StubResponse.text("Bad gateway", status: 502),
        .failure(.notConnectedToInternet),
        .failure(.timedOut),
    ])
    func expiringTokenIsReturnedWhenRefreshFailsTransiently(refresh: StubResponse) async throws {
        let token = makeJWT(expiringAt: now.addingTimeInterval(60))
        let (client, server, tokens) = try await makeExpiryClient(accessToken: token, refresh: refresh)

        #expect(try await client.accessToken(replacing: nil) == token)
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(tokens.current?.accessToken == token)
    }

    @Test func expiredTokenThrowsWhenRefreshFailsTransiently() async throws {
        let (client, _, tokens) = try await makeExpiryClient(
            accessToken: makeJWT(expiringAt: now.addingTimeInterval(-10)),
            refresh: .text("Bad gateway", status: 502))

        await #expect(throws: APIError.http(status: 502, message: "Bad gateway")) {
            try await client.accessToken(replacing: nil)
        }
        #expect(tokens.expiredCount == 0)
    }

    @Test func expiringTokenWithRejectedRefreshThrowsSessionExpired() async throws {
        let (client, _, tokens) = try await makeExpiryClient(
            accessToken: makeJWT(expiringAt: now.addingTimeInterval(60)),
            refresh: .text("Invalid refresh token", status: 401))

        await #expect(throws: APIError.sessionExpired) {
            try await client.accessToken(replacing: nil)
        }
        #expect(tokens.current == nil)
    }
}

private func refreshJSON(_ accessToken: String) -> String {
    #"{"user":{"accessToken":"\#(accessToken)","refreshToken":"refresh-2"}}"#
}

private let expiringToken = makeJWT(expiringAt: now.addingTimeInterval(60))
private let newSession = AuthTokens(accessToken: "access-new", refreshToken: "refresh-new")

/// A clock tests can move forward.
private final class TestClock: Sendable {
    private let date = Mutex(now)
    func read() -> Date { date.withLock { $0 } }
    func advance(by interval: TimeInterval) { date.withLock { $0 += interval } }
}

@Suite struct APIClientTokenExpiryRaceTests {
    @Test func transientFailureAfterSignOutThrowsNotAuthenticated() async throws {
        let gate = StubGate()
        let (client, _, tokens) = try await makeExpiryClient(
            accessToken: expiringToken, refresh: .text("Bad gateway", status: 502, gate: gate))

        let token = Task { try await client.accessToken(replacing: nil) }
        await gate.arrived()
        tokens.signOut()
        gate.open()

        await #expect(throws: APIError.notAuthenticated) { try await token.value }
    }

    @Test func transientFailureAfterNewSignInReturnsNewToken() async throws {
        let gate = StubGate()
        let (client, _, tokens) = try await makeExpiryClient(
            accessToken: expiringToken, refresh: .text("Bad gateway", status: 502, gate: gate))

        let token = Task { try await client.accessToken(replacing: nil) }
        await gate.arrived()
        tokens.signIn(newSession)
        gate.open()

        #expect(try await token.value == "access-new")
    }

    @Test func successfulRefreshRacingNewSignInReturnsNewToken() async throws {
        let gate = StubGate()
        let (client, _, tokens) = try await makeExpiryClient(
            accessToken: expiringToken, refresh: .json(refreshJSON(freshToken), gate: gate))

        let token = Task { try await client.accessToken(replacing: nil) }
        await gate.arrived()
        tokens.signIn(newSession)
        gate.open()

        #expect(try await token.value == "access-new")
        #expect(tokens.current == newSession)
        #expect(tokens.updates.isEmpty)
    }

    @Test func successfulRefreshRacingSignOutThrowsNotAuthenticated() async throws {
        let gate = StubGate()
        let (client, _, tokens) = try await makeExpiryClient(
            accessToken: expiringToken, refresh: .json(refreshJSON(freshToken), gate: gate))

        let token = Task { try await client.accessToken(replacing: nil) }
        await gate.arrived()
        tokens.signOut()
        gate.open()

        await #expect(throws: APIError.notAuthenticated) { try await token.value }
        #expect(tokens.current == nil)
    }

    @Test func expiringTokenJoinsRefreshStartedByUnauthorizedRequest() async throws {
        let gate = StubGate()
        let server = StubServer { request in
            if request.url?.path() == refreshPath { return .json(refreshJSON(freshToken), gate: gate) }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer \(freshToken)" {
                return .json(#"{"ok":true}"#)
            }
            return .text("Unauthorized", status: 401)
        }
        let tokens = InMemoryTokenProvider(AuthTokens(accessToken: expiringToken, refreshToken: "refresh-1"))
        let client = try makeClient(server, tokens: tokens)
        await client.setNow { now }
        let joins = Checkpoint()
        await client.observeRefreshJoins { joins.pass() }

        let response = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        await gate.arrived()
        let token = Task { try await client.accessToken(replacing: nil) }
        await joins.reached()
        gate.open()

        #expect(try await token.value == freshToken)
        #expect(try await response.value == OK(ok: true))
        #expect(server.requests(path: refreshPath).count == 1)
    }

    @Test func tokenFarFromExpiryDoesNotWaitForRunningRefresh() async throws {
        let gate = StubGate()
        let stored = makeJWT(expiringAt: now.addingTimeInterval(7200))
        let server = StubServer { request in
            if request.url?.path() == refreshPath { return .json(refreshJSON(freshToken), gate: gate) }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer \(freshToken)" {
                return .json(#"{"ok":true}"#)
            }
            return .text("Unauthorized", status: 401)
        }
        let tokens = InMemoryTokenProvider(AuthTokens(accessToken: stored, refreshToken: "refresh-1"))
        let client = try makeClient(server, tokens: tokens)
        await client.setNow { now }

        let response = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        await gate.arrived()
        // Returns while the refresh is still held, so it didn't join it.
        #expect(try await client.accessToken(replacing: nil) == stored)
        gate.open()

        #expect(try await response.value == OK(ok: true))
        #expect(server.requests(path: refreshPath).count == 1)
    }

    @Test func nonTransientRefreshFailuresThrowAndKeepTokens() async throws {
        let other = StubServer { _ in .json(refreshJSON("access-evil")) }
        let failures: [(StubResponse, (APIError) -> Bool)] = [
            (.text("Forbidden", status: 403), { $0 == .forbidden(message: "Forbidden") }),
            (.json(#"{"nope":1}"#), { if case .decoding = $0 { true } else { false } }),
            (.redirect(to: "https://\(other.host)/x", status: 307), { $0 == .redirectRefused(status: 307) }),
        ]
        for (refresh, matches) in failures {
            let (client, _, tokens) = try await makeExpiryClient(accessToken: expiringToken, refresh: refresh)
            do {
                _ = try await client.accessToken(replacing: nil)
                Issue.record("Expected an error")
            } catch let error as APIError {
                #expect(matches(error), "\(error)")
            }
            #expect(tokens.current == AuthTokens(accessToken: expiringToken, refreshToken: "refresh-1"))
            #expect(tokens.updates.isEmpty)
            #expect(tokens.expiredCount == 0)
        }
        #expect(other.requests.isEmpty)
    }

    @Test func transientFailureAtExactExpiryThrows() async throws {
        let (client, _, _) = try await makeExpiryClient(
            accessToken: makeJWT(expiringAt: now), refresh: .text("Bad gateway", status: 502))

        await #expect(throws: APIError.http(status: 502, message: "Bad gateway")) {
            try await client.accessToken(replacing: nil)
        }
    }
}

@Suite struct APIClientTokenClockSkewTests {
    /// The server's clock is an hour behind this device, so a token it just issued looks
    /// expired by this device's clock.
    @Test func refreshedTokenFromSkewedServerIsNotRefreshedAgain() async throws {
        let skewed = makeJWT(
            claims: #"{"iat":\#(Int(now.timeIntervalSince1970) - 3600),"exp":\#(Int(now.timeIntervalSince1970))}"#)
        let (client, server, tokens) = try await makeExpiryClient(
            accessToken: expiringToken, refresh: .json(refreshJSON(skewed)))
        let clock = TestClock()
        await client.setNow { clock.read() }

        #expect(try await client.accessToken(replacing: nil) == skewed)
        #expect(try await client.accessToken(replacing: nil) == skewed)
        #expect(server.requests(path: refreshPath).count == 1)

        // Timed from its arrival, it nears expiry an hour later.
        clock.advance(by: 3600 - 121)
        #expect(try await client.accessToken(replacing: nil) == skewed)
        #expect(server.requests(path: refreshPath).count == 1)
        clock.advance(by: 2)
        _ = try await client.accessToken(replacing: nil)
        #expect(server.requests(path: refreshPath).count == 2)
        #expect(tokens.updates.count == 2)
    }

    /// A refreshed token without `iat` that arrives 30 s from its `exp` isn't refreshed early,
    /// but is refreshed once that `exp` passes rather than returned expired forever.
    @Test func refreshedTokenWithoutIssuedAtThatLooksExpiringIsRefreshedAfterExp() async throws {
        let refreshed = makeJWT(expiringAt: now.addingTimeInterval(30))
        let (client, server, _) = try await makeExpiryClient(
            accessToken: expiringToken, refresh: .json(refreshJSON(refreshed)))
        let clock = TestClock()
        await client.setNow { clock.read() }
        let refreshes = { server.requests(path: refreshPath).count }

        #expect(try await client.accessToken(replacing: nil) == refreshed)
        #expect(try await client.accessToken(replacing: nil) == refreshed)
        clock.advance(by: 29)
        #expect(try await client.accessToken(replacing: nil) == refreshed)
        #expect(refreshes() == 1)
        clock.advance(by: 2)
        _ = try await client.accessToken(replacing: nil)
        #expect(refreshes() == 2)
        // The server returned the same token, already expired on arrival: not chased again.
        _ = try await client.accessToken(replacing: nil)
        #expect(refreshes() == 2)
    }

    @Test func tokenExpiringAtOrBeforeIssueIsNotRefreshedEarly() async throws {
        let t = Int(now.timeIntervalSince1970)
        let token = makeJWT(claims: #"{"iat":\#(t),"exp":\#(t)}"#)
        let (client, server, _) = try await makeExpiryClient(accessToken: token)

        #expect(try await client.accessToken(replacing: nil) == token)
        #expect(server.requests.isEmpty)
    }

    /// A 100 s lifetime gets a 50 s leeway rather than 120 s.
    @Test func shortLivedTokenUsesHalfItsLifetimeAsLeeway() async throws {
        let t = Int(now.timeIntervalSince1970)
        let outside = makeJWT(claims: #"{"iat":\#(t - 40),"exp":\#(t + 60)}"#)
        let (client, server, _) = try await makeExpiryClient(accessToken: outside)
        #expect(try await client.accessToken(replacing: nil) == outside)
        #expect(server.requests.isEmpty)

        let inside = makeJWT(claims: #"{"iat":\#(t - 60),"exp":\#(t + 40)}"#)
        let (insideClient, insideServer, _) = try await makeExpiryClient(accessToken: inside)
        #expect(try await insideClient.accessToken(replacing: nil) == freshToken)
        #expect(insideServer.requests(path: refreshPath).count == 1)
    }
}

@Suite struct APIErrorTransientTests {
    @Test(arguments: [
        (APIError.http(status: 408, message: nil), true),
        (.http(status: 429, message: nil), true),
        (.http(status: 499, message: nil), false),
        (.http(status: 500, message: nil), true),
        (.http(status: 599, message: nil), true),
        (.http(status: 600, message: nil), false),
        (.forbidden(message: nil), false),
        (.decoding("bad"), false),
        (.timedOut, true),
        (.network(.notConnectedToInternet), true),
        (.network(.networkConnectionLost), true),
        (.network(.dataNotAllowed), true),
        (.network(.secureConnectionFailed), false),
        (.network(.serverCertificateUntrusted), false),
        (.network(.appTransportSecurityRequiresSecureConnection), false),
        (.network(.badURL), false),
    ])
    func classifiesTransientErrors(error: APIError, isTransient: Bool) {
        #expect(error.isTransient == isTransient)
    }
}

/// Signs the user out right after committing a refresh, before the client re-reads the tokens.
private final class SignOutAfterSwapProvider: TokenProvider {
    let inner: InMemoryTokenProvider

    init(_ tokens: AuthTokens) {
        inner = InMemoryTokenProvider(tokens)
    }

    func tokens() async -> AuthTokens? {
        await inner.tokens()
    }

    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool {
        guard await inner.replaceTokens(expected: expected, with: new) else { return false }
        inner.signOut()
        return true
    }

    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool {
        await inner.expireSession(ifCurrent: rejected)
    }
}

@Suite struct APIClientTokenRefreshFollowUpTests {
    @Test func signOutAfterJoinedRefreshSucceedsThrowsNotAuthenticated() async throws {
        let gate = StubGate()
        let server = StubServer { request in
            if request.url?.path() == refreshPath { return .json(refreshJSON(freshToken), gate: gate) }
            return .text("Unauthorized", status: 401)
        }
        let tokens = SignOutAfterSwapProvider(AuthTokens(accessToken: expiringToken, refreshToken: "refresh-1"))
        let client = try makeClient(server, tokens: tokens)
        await client.setNow { now }
        let joins = Checkpoint()
        await client.observeRefreshJoins { joins.pass() }

        let response = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        await gate.arrived()
        let token = Task { try await client.accessToken(replacing: nil) }
        await joins.reached()
        gate.open()

        await #expect(throws: APIError.notAuthenticated) { try await token.value }
        _ = try? await response.value
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(tokens.inner.expiredCount == 0)
    }

    @Test func cancelledCallerGetsCancellationErrorWhenSessionIsReplaced() async throws {
        let gate = StubGate()
        let (client, _, tokens) = try await makeExpiryClient(
            accessToken: expiringToken, refresh: .json(refreshJSON(freshToken), gate: gate))

        let token = Task { try await client.accessToken(replacing: nil) }
        await gate.arrived()
        tokens.signIn(newSession)
        token.cancel()
        gate.open()

        await #expect(throws: CancellationError.self) { try await token.value }
    }

    @Test func transientFailuresPauseEarlyRefreshesButNotReactiveOnes() async throws {
        let (client, server, _) = try await makeExpiryClient(
            accessToken: expiringToken, refresh: .text("Bad gateway", status: 502))
        let clock = TestClock()
        await client.setNow { clock.read() }
        let refreshes = { server.requests(path: refreshPath).count }

        #expect(try await client.accessToken(replacing: nil) == expiringToken)
        #expect(refreshes() == 1)
        clock.advance(by: 10)
        #expect(try await client.accessToken(replacing: nil) == expiringToken)
        #expect(refreshes() == 1)
        // A 401 still refreshes during the pause.
        await #expect(throws: APIError.http(status: 502, message: "Bad gateway")) {
            try await client.accessToken(replacing: expiringToken)
        }
        #expect(refreshes() == 2)

        // The pause is a quarter of the 120 s leeway; the failure after it starts another.
        clock.advance(by: 21)
        #expect(try await client.accessToken(replacing: nil) == expiringToken)
        #expect(refreshes() == 3)
        clock.advance(by: 9)
        #expect(try await client.accessToken(replacing: nil) == expiringToken)
        #expect(refreshes() == 3)

        // Once the token has expired there's no pause, and the failure is thrown.
        clock.advance(by: 21)
        await #expect(throws: APIError.http(status: 502, message: "Bad gateway")) {
            try await client.accessToken(replacing: nil)
        }
        #expect(refreshes() == 4)
    }

    /// A stored token from a server whose clock is an hour behind this device looks expired, so
    /// it's refreshed once; the token that refresh returns is timed from its arrival.
    @Test func storedTokenFromSkewedServerIsRefreshedOnce() async throws {
        let t = Int(now.timeIntervalSince1970)
        let stored = makeJWT(claims: #"{"n":"stored","iat":\#(t - 3600),"exp":\#(t)}"#)
        let refreshed = makeJWT(claims: #"{"n":"refreshed","iat":\#(t - 3600),"exp":\#(t)}"#)
        let (client, server, _) = try await makeExpiryClient(
            accessToken: stored, refresh: .json(refreshJSON(refreshed)))

        #expect(try await client.accessToken(replacing: nil) == refreshed)
        #expect(try await client.accessToken(replacing: nil) == refreshed)
        #expect(server.requests(path: refreshPath).count == 1)
    }

    @Test func refreshedTokenWithoutIssuedAtUsesItsExp() async throws {
        let refreshed = makeJWT(expiringAt: now.addingTimeInterval(600))
        let (client, server, _) = try await makeExpiryClient(
            accessToken: expiringToken, refresh: .json(refreshJSON(refreshed)))
        let clock = TestClock()
        await client.setNow { clock.read() }

        #expect(try await client.accessToken(replacing: nil) == refreshed)
        #expect(try await client.accessToken(replacing: nil) == refreshed)
        #expect(server.requests(path: refreshPath).count == 1)
        clock.advance(by: 600 - 121)
        #expect(try await client.accessToken(replacing: nil) == refreshed)
        #expect(server.requests(path: refreshPath).count == 1)
        clock.advance(by: 2)
        _ = try await client.accessToken(replacing: nil)
        #expect(server.requests(path: refreshPath).count == 2)
    }
}

/// Wraps an ``InMemoryTokenProvider`` and holds the first successful swap after committing it
/// until ``release()``. ``held()`` returns once it's holding.
private final class HeldFirstSwapProvider: TokenProvider {
    let inner: InMemoryTokenProvider
    private let swaps = Mutex(0)
    private let holding = Checkpoint()
    private let released = Checkpoint()

    init(_ tokens: AuthTokens) {
        inner = InMemoryTokenProvider(tokens)
    }

    func held() async { await holding.reached() }
    func release() { released.pass() }

    func tokens() async -> AuthTokens? {
        await inner.tokens()
    }

    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool {
        guard await inner.replaceTokens(expected: expected, with: new) else { return false }
        let swap = swaps.withLock {
            $0 += 1
            return $0
        }
        if swap == 1 {
            holding.pass()
            await released.reached()
        }
        return true
    }

    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool {
        await inner.expireSession(ifCurrent: rejected)
    }
}

@Suite struct APIClientTokenReviewTests {
    @Test func cancelledCallersOfSharedRefreshThrowWhileOthersGetToken() async throws {
        let gate = StubGate()
        let (client, server, _) = try await makeExpiryClient(
            accessToken: expiringToken, refresh: .json(refreshJSON(freshToken), gate: gate))
        let joins = Checkpoint()
        await client.observeRefreshJoins { joins.pass() }

        let first = Task { try await client.accessToken(replacing: nil) }
        await gate.arrived()
        let cancelledEarly = Task { try await client.accessToken(replacing: nil) }
        let cancelledReactive = Task { try await client.accessToken(replacing: expiringToken) }
        let other = Task { try await client.accessToken(replacing: nil) }
        await joins.reached(3)
        first.cancel()
        cancelledEarly.cancel()
        cancelledReactive.cancel()
        gate.open()

        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await cancelledEarly.value }
        await #expect(throws: CancellationError.self) { try await cancelledReactive.value }
        #expect(try await other.value == freshToken)
        #expect(server.requests(path: refreshPath).count == 1)
    }

    @Test func cancelledCallerDoesNotGetTransientFallbackToken() async throws {
        let gate = StubGate()
        let (client, _, _) = try await makeExpiryClient(
            accessToken: expiringToken, refresh: .text("Bad gateway", status: 502, gate: gate))
        let joins = Checkpoint()
        await client.observeRefreshJoins { joins.pass() }

        let cancelled = Task { try await client.accessToken(replacing: nil) }
        await gate.arrived()
        let other = Task { try await client.accessToken(replacing: nil) }
        await joins.reached()
        cancelled.cancel()
        gate.open()

        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await other.value == expiringToken)
    }

    /// A→B commits but returns late, after B→C has completed. C's receipt must survive, or C
    /// (issued by a server whose clock is an hour behind) looks expired and is refreshed again.
    @Test func lateRefreshDoesNotReplaceNewerReceipt() async throws {
        let t = Int(now.timeIntervalSince1970)
        let tokenB = makeJWT(claims: #"{"n":"B","iat":\#(t - 3600),"exp":\#(t)}"#)
        let tokenC = makeJWT(claims: #"{"n":"C","iat":\#(t - 3600),"exp":\#(t)}"#)
        let server = StubServer { request in
            switch request.value(forHTTPHeaderField: "x-refresh-token") {
            case "refresh-1": .json(#"{"user":{"accessToken":"\#(tokenB)","refreshToken":"refresh-2"}}"#)
            case "refresh-2": .json(#"{"user":{"accessToken":"\#(tokenC)","refreshToken":"refresh-3"}}"#)
            default: .text("Unexpected", status: 500)
            }
        }
        let tokens = HeldFirstSwapProvider(AuthTokens(accessToken: expiringToken, refreshToken: "refresh-1"))
        let client = try makeClient(server, tokens: tokens)
        await client.setNow { now }

        let first = Task { try await client.accessToken(replacing: nil) }
        await tokens.held()
        // B is stored but its refresh hasn't returned; a 401 for B refreshes it to C.
        #expect(try await client.accessToken(replacing: tokenB) == tokenC)
        tokens.release()
        #expect(try await first.value == tokenC)

        #expect(try await client.accessToken(replacing: nil) == tokenC)
        #expect(server.requests(path: refreshPath).count == 2)
    }
}

/// Wraps an ``InMemoryTokenProvider`` and holds a read made by a task tagged with
/// ``isHeldReader`` once a swap has succeeded, until ``release()``, then reads the stored pair.
private final class HeldReadAfterSwapProvider: TokenProvider {
    @TaskLocal static var isHeldReader = false

    let inner: InMemoryTokenProvider
    private let swapped = Mutex(false)
    private let holding = Checkpoint()
    private let released = Checkpoint()

    init(_ tokens: AuthTokens) {
        inner = InMemoryTokenProvider(tokens)
    }

    func held() async { await holding.reached() }
    func release() { released.pass() }

    func tokens() async -> AuthTokens? {
        if Self.isHeldReader, swapped.withLock({ $0 }) {
            holding.pass()
            await released.reached()
        }
        return await inner.tokens()
    }

    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool {
        guard await inner.replaceTokens(expected: expected, with: new) else { return false }
        swapped.withLock { $0 = true }
        return true
    }

    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool {
        await inner.expireSession(ifCurrent: rejected)
    }
}

@Suite struct APIClientTokenLineageTests {
    /// A `nil` caller joins A→B; a request retries B, gets another 401 and expires B before the
    /// caller reads the provider. The server ended the session, so the caller gets
    /// `.sessionExpired`, not the local sign-out's `.notAuthenticated`.
    @Test func expiryOfRefreshedDescendantIsSessionExpired() async throws {
        let gate = StubGate()
        let server = StubServer { request in
            request.url?.path == refreshPath
                ? .json(refreshJSON(freshToken), gate: gate) : .text("Unauthorized", status: 401)
        }
        let tokens = HeldReadAfterSwapProvider(AuthTokens(accessToken: expiringToken, refreshToken: "refresh-1"))
        let client = try makeClient(server, tokens: tokens)
        await client.setNow { now }
        let joins = Checkpoint()
        await client.observeRefreshJoins { joins.pass() }

        let request = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        await gate.arrived()
        let caller = Task {
            try await HeldReadAfterSwapProvider.$isHeldReader.withValue(true) {
                try await client.accessToken(replacing: nil)
            }
        }
        await joins.reached()
        gate.open()
        await tokens.held()
        await #expect(throws: APIError.sessionExpired) { try await request.value }
        tokens.release()

        await #expect(throws: APIError.sessionExpired) { try await caller.value }
        #expect(server.requests(path: refreshPath).count == 1)
    }

    /// A lookup while a refresh's swap has stored the new pair but not returned sees the new
    /// token with its receipt: a token from a server clock an hour behind isn't refreshed again.
    @Test func lookupDuringHeldSwapUsesNewTokensReceipt() async throws {
        let t = Int(now.timeIntervalSince1970)
        let tokenB = makeJWT(claims: #"{"n":"B","iat":\#(t - 3600),"exp":\#(t)}"#)
        let tokenC = makeJWT(claims: #"{"n":"C","iat":\#(t - 3600),"exp":\#(t)}"#)
        let server = StubServer { request in
            switch request.value(forHTTPHeaderField: "x-refresh-token") {
            case "refresh-1": .json(#"{"user":{"accessToken":"\#(tokenB)","refreshToken":"refresh-2"}}"#)
            case "refresh-2": .json(#"{"user":{"accessToken":"\#(tokenC)","refreshToken":"refresh-3"}}"#)
            default: .text("Unexpected", status: 500)
            }
        }
        let tokens = HeldFirstSwapProvider(AuthTokens(accessToken: expiringToken, refreshToken: "refresh-1"))
        let client = try makeClient(server, tokens: tokens)
        await client.setNow { now }

        let first = Task { try await client.accessToken(replacing: nil) }
        await tokens.held()
        #expect(try await client.accessToken(replacing: nil) == tokenB)
        tokens.release()
        #expect(try await first.value == tokenB)

        #expect(try await client.accessToken(replacing: nil) == tokenB)
        #expect(server.requests(path: refreshPath).count == 1)
    }
}

/// Wraps an ``InMemoryTokenProvider``. Once a swap has succeeded, holds a read by a task tagged
/// with ``isHeldReader`` until ``releaseRead()``; holds every expiration after it has cleared
/// the tokens until ``releaseExpiry()``.
private final class HeldExpiryProvider: TokenProvider {
    @TaskLocal static var isHeldReader = false

    let inner: InMemoryTokenProvider
    private let swapped = Mutex(false)
    private let readHolding = Checkpoint()
    private let readReleased = Checkpoint()
    private let expiryHolding = Checkpoint()
    private let expiryReleased = Checkpoint()

    init(_ tokens: AuthTokens) {
        inner = InMemoryTokenProvider(tokens)
    }

    func readHeld() async { await readHolding.reached() }
    func releaseRead() { readReleased.pass() }
    func expiryHeld() async { await expiryHolding.reached() }
    func releaseExpiry() { expiryReleased.pass() }

    func tokens() async -> AuthTokens? {
        if Self.isHeldReader, swapped.withLock({ $0 }) {
            readHolding.pass()
            await readReleased.reached()
        }
        return await inner.tokens()
    }

    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool {
        guard await inner.replaceTokens(expected: expected, with: new) else { return false }
        swapped.withLock { $0 = true }
        return true
    }

    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool {
        let expired = await inner.expireSession(ifCurrent: rejected)
        expiryHolding.pass()
        await expiryReleased.reached()
        return expired
    }
}

@Suite struct APIClientTokenReceiptAndExpiryTests {
    /// A refresh that returns the same token (with `iat`) keeps its first receipt, so the
    /// token's lifetime isn't restarted: a one-hour token received at t=0 and returned again at
    /// t=3500 is refreshed once it expires at t=3600.
    @Test func sameTokenReturnedKeepsOriginalReceipt() async throws {
        let t = Int(now.timeIntervalSince1970)
        let token = makeJWT(claims: #"{"iat":\#(t),"exp":\#(t + 3600)}"#)
        let (client, server, _) = try await makeExpiryClient(
            accessToken: expiringToken, refresh: .json(refreshJSON(token)))
        let clock = TestClock()
        await client.setNow { clock.read() }
        let refreshes = { server.requests(path: refreshPath).count }

        #expect(try await client.accessToken(replacing: nil) == token)
        #expect(refreshes() == 1)
        clock.advance(by: 3500)
        #expect(try await client.accessToken(replacing: nil) == token)
        #expect(refreshes() == 2)
        clock.advance(by: 101)
        _ = try await client.accessToken(replacing: nil)
        #expect(refreshes() == 3)
    }

    /// The provider clears the tokens before its expiration call returns. A `nil` caller that
    /// joined the refresh and reads the cleared tokens in that window still gets
    /// `.sessionExpired`: the server ended the session, not a local sign-out.
    @Test func callerReadingDuringPendingExpiryGetsSessionExpired() async throws {
        let gate = StubGate()
        let server = StubServer { request in
            request.url?.path == refreshPath
                ? .json(refreshJSON(freshToken), gate: gate) : .text("Unauthorized", status: 401)
        }
        let tokens = HeldExpiryProvider(AuthTokens(accessToken: expiringToken, refreshToken: "refresh-1"))
        let client = try makeClient(server, tokens: tokens)
        await client.setNow { now }
        let joins = Checkpoint()
        await client.observeRefreshJoins { joins.pass() }

        let request = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        await gate.arrived()
        let caller = Task {
            try await HeldExpiryProvider.$isHeldReader.withValue(true) {
                try await client.accessToken(replacing: nil)
            }
        }
        await joins.reached()
        gate.open()
        // The request retries the refreshed pair, gets another 401 and expires it; the provider
        // has cleared the tokens but its call hasn't returned.
        await tokens.readHeld()
        await tokens.expiryHeld()
        tokens.releaseRead()
        // Gives the caller time to classify the error while the expiry is still pending.
        try await Task.sleep(for: .milliseconds(100))
        tokens.releaseExpiry()

        await #expect(throws: APIError.sessionExpired) { try await caller.value }
        await #expect(throws: APIError.sessionExpired) { try await request.value }
    }
}

/// Wraps an ``InMemoryTokenProvider`` and holds a swap of a pair with refresh token `refresh-1`,
/// before its compare-and-swap, until ``release()``. ``held()`` returns once it's holding.
private final class HeldFirstPairSwapProvider: TokenProvider {
    let inner: InMemoryTokenProvider
    private let holding = Checkpoint()
    private let released = Checkpoint()

    init(_ tokens: AuthTokens) {
        inner = InMemoryTokenProvider(tokens)
    }

    func held() async { await holding.reached() }
    func release() { released.pass() }

    func tokens() async -> AuthTokens? {
        await inner.tokens()
    }

    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool {
        if expected.refreshToken == "refresh-1" {
            holding.pass()
            await released.reached()
        }
        return await inner.replaceTokens(expected: expected, with: new)
    }

    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool {
        await inner.expireSession(ifCurrent: rejected)
    }
}

@Suite struct APIClientTokenBookkeepingTests {
    /// A `nil` caller for A joins A→A1; before it reads the tokens, the server expires A1 and
    /// then a later session B. The caller still gets `.sessionExpired`: A1's expiry is kept,
    /// not replaced by B's.
    @Test func expiryOfLineageSurvivesLaterSessionExpiry() async throws {
        let gate = StubGate()
        let server = StubServer { request in
            switch (request.url?.path, request.value(forHTTPHeaderField: "x-refresh-token")) {
            case (refreshPath, "refresh-1"): .json(refreshJSON(freshToken), gate: gate)
            default: .text("Unauthorized", status: 401)
            }
        }
        let tokens = HeldReadAfterSwapProvider(AuthTokens(accessToken: expiringToken, refreshToken: "refresh-1"))
        let client = try makeClient(server, tokens: tokens)
        await client.setNow { now }
        let joins = Checkpoint()
        await client.observeRefreshJoins { joins.pass() }

        let request = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        await gate.arrived()
        let caller = Task {
            try await HeldReadAfterSwapProvider.$isHeldReader.withValue(true) {
                try await client.accessToken(replacing: nil)
            }
        }
        await joins.reached()
        gate.open()
        await tokens.held()
        // The request retries A1, gets another 401 and expires it.
        await #expect(throws: APIError.sessionExpired) { try await request.value }
        // A new session B, whose refresh token the server rejects too.
        tokens.inner.signIn(AuthTokens(accessToken: "access-B", refreshToken: "refresh-B"))
        await #expect(throws: APIError.sessionExpired) { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        tokens.release()

        await #expect(throws: APIError.sessionExpired) { try await caller.value }
    }

    /// Refreshes of two pairs return the same token T (with `iat`, from a server clock an hour
    /// behind). The second swap succeeds; the first, held, then fails. T keeps its receipt, so
    /// it isn't refreshed again.
    @Test func failedSwapDoesNotRemoveReceiptOfSameTokenStoredBySuccessfulSwap() async throws {
        let t = Int(now.timeIntervalSince1970)
        let tokenT = makeJWT(claims: #"{"n":"T","iat":\#(t - 3600),"exp":\#(t)}"#)
        let server = StubServer { request in
            switch request.value(forHTTPHeaderField: "x-refresh-token") {
            case "refresh-1": .json(#"{"user":{"accessToken":"\#(tokenT)","refreshToken":"refresh-1b"}}"#)
            case "refresh-2": .json(#"{"user":{"accessToken":"\#(tokenT)","refreshToken":"refresh-2b"}}"#)
            default: .text("Unexpected", status: 500)
            }
        }
        let tokens = HeldFirstPairSwapProvider(AuthTokens(accessToken: expiringToken, refreshToken: "refresh-1"))
        let client = try makeClient(server, tokens: tokens)
        await client.setNow { now }

        let first = Task { try await client.accessToken(replacing: nil) }
        await tokens.held()
        tokens.inner.signIn(
            AuthTokens(accessToken: makeJWT(expiringAt: now.addingTimeInterval(61)), refreshToken: "refresh-2"))
        #expect(try await client.accessToken(replacing: nil) == tokenT)
        tokens.release()
        #expect(try await first.value == tokenT)

        #expect(try await client.accessToken(replacing: nil) == tokenT)
        #expect(server.requests(path: refreshPath).count == 2)
    }

    /// An early refresh of an old pair that fails transiently after the current pair's did
    /// doesn't lift the current pair's pause.
    @Test func lateTransientFailureOfOldPairKeepsCurrentPairsPause() async throws {
        let gate = StubGate()
        let server = StubServer { request in
            switch request.value(forHTTPHeaderField: "x-refresh-token") {
            case "refresh-1": .text("Bad gateway", status: 502, gate: gate)
            default: .text("Bad gateway", status: 502)
            }
        }
        let tokens = InMemoryTokenProvider(AuthTokens(accessToken: expiringToken, refreshToken: "refresh-1"))
        let client = try makeClient(server, tokens: tokens)
        await client.setNow { now }
        let second = makeJWT(expiringAt: now.addingTimeInterval(61))

        let first = Task { try await client.accessToken(replacing: nil) }
        await gate.arrived()
        tokens.signIn(AuthTokens(accessToken: second, refreshToken: "refresh-2"))
        #expect(try await client.accessToken(replacing: nil) == second)
        gate.open()
        #expect(try await first.value == second)

        #expect(try await client.accessToken(replacing: nil) == second)
        #expect(server.requests(path: refreshPath).count == 2)
    }
}
