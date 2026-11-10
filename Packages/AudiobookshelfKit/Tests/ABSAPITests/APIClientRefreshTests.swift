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

/// Returns `access-1` once, then `access-2`, as if another request refreshed in between.
private actor RotatedTokenProvider: TokenProvider {
    private var calls = 0

    func tokens() -> AuthTokens? {
        calls += 1
        return calls == 1
            ? AuthTokens(accessToken: "access-1", refreshToken: "refresh-1")
            : AuthTokens(accessToken: "access-2", refreshToken: "refresh-2")
    }

    func replaceTokens(expected: AuthTokens, with new: AuthTokens) -> Bool { false }
    func expireSession(ifCurrent rejected: AuthTokens) -> Bool { false }
}

/// Wraps an ``InMemoryTokenProvider`` and holds the `heldCall`-th `tokens()` read (after taking
/// its snapshot) until ``release()``, to simulate a slow read that returns an old pair.
private final class GatedTokenProvider: TokenProvider {
    private struct State {
        var calls = 0
        var isHolding = false
        var released = false
    }

    let inner = InMemoryTokenProvider()
    private let heldCall: Int
    private let state = Mutex(State())

    init(holdingCall heldCall: Int) {
        self.heldCall = heldCall
    }

    var isHolding: Bool { state.withLock { $0.isHolding } }

    func release() {
        state.withLock { $0.released = true }
    }

    func tokens() async -> AuthTokens? {
        let snapshot = await inner.tokens()
        let hold = state.withLock {
            $0.calls += 1
            $0.isHolding = $0.calls == heldCall
            return $0.isHolding
        }
        if hold {
            while !state.withLock({ $0.released }) { try? await Task.sleep(for: .milliseconds(5)) }
        }
        return snapshot
    }

    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool {
        await inner.replaceTokens(expected: expected, with: new)
    }

    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool {
        await inner.expireSession(ifCurrent: rejected)
    }
}

/// Wraps an ``InMemoryTokenProvider`` and, after committing its first successful swap, waits for
/// ``release()`` before returning, so a later refresh can finish first.
private final class SlowFirstSwapTokenProvider: TokenProvider {
    private struct State {
        var swaps = 0
        var isHolding = false
        var released = false
    }

    let inner = InMemoryTokenProvider()
    private let state = Mutex(State())

    var isHolding: Bool { state.withLock { $0.isHolding } }

    func release() {
        state.withLock { $0.released = true }
    }

    func tokens() async -> AuthTokens? {
        await inner.tokens()
    }

    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool {
        guard await inner.replaceTokens(expected: expected, with: new) else { return false }
        let hold = state.withLock {
            $0.swaps += 1
            $0.isHolding = $0.swaps == 1
            return $0.isHolding
        }
        if hold {
            while !state.withLock({ $0.released }) { try? await Task.sleep(for: .milliseconds(5)) }
        }
        return true
    }

    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool {
        await inner.expireSession(ifCurrent: rejected)
    }
}

private func makeClient(_ server: StubServer, tokens: any TokenProvider) throws -> APIClient {
    APIClient(
        configuration: try APIClientConfiguration(baseURL: server.baseURL, customHeaders: ["X-Proxy": "1"]),
        tokenProvider: tokens,
        sessionConfiguration: server.sessionConfiguration()
    )
}

@Suite struct APIClientRefreshTests {
    @Test func refreshesOnUnauthorizedAndRetriesOnce() async throws {
        let server = tokenServer(refresh: .json(refreshedJSON))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        let result = try await client.send(Endpoint<OK>(.get, "/api/me"))

        #expect(result == OK(ok: true))
        let paths = server.requests.map { $0.url?.path() }
        #expect(paths == ["/abs/api/me", refreshPath, "/abs/api/me"])
        let refresh = try #require(server.requests(path: refreshPath).first)
        #expect(refresh.httpMethod == "POST")
        #expect(refresh.value(forHTTPHeaderField: "x-refresh-token") == "refresh-1")
        #expect(refresh.value(forHTTPHeaderField: "X-Proxy") == "1")
        #expect(refresh.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(server.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer access-2")
        #expect(tokens.updates == [AuthTokens(accessToken: "access-2", refreshToken: "refresh-2")])
        #expect(tokens.expiredCount == 0)
    }

    @Test func keepsRefreshTokenWhenResponseOmitsIt() async throws {
        let server = tokenServer(refresh: .json(#"{"user":{"accessToken":"access-2"}}"#))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        _ = try await client.send(Endpoint<OK>(.get, "/api/me"))

        #expect(tokens.current == AuthTokens(accessToken: "access-2", refreshToken: "refresh-1"))
    }

    @Test func concurrentUnauthorizedRequestsShareOneRefresh() async throws {
        let server = tokenServer(refresh: .json(refreshedJSON, delay: .milliseconds(200)))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        let results = try await withThrowingTaskGroup(of: OK.self) { group in
            for index in 0..<8 {
                group.addTask { try await client.send(Endpoint<OK>(.get, "/api/items/\(index)")) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(results.count == 8)
        let rejected = server.requests.filter { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-1" }
        #expect(rejected.count > 1)
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(tokens.updates.count == 1)
    }

    @Test func rejectedRefreshExpiresSession() async throws {
        let server = tokenServer(refresh: .text("Invalid refresh token", status: 401))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        await #expect(throws: APIError.sessionExpired) {
            try await client.send(Endpoint<OK>(.get, "/api/me"))
        }
        #expect(tokens.expiredCount == 1)
        #expect(tokens.current == nil)
        #expect(server.requests(path: "/abs/api/me").count == 1)
    }

    @Test func forbiddenRefreshKeepsSession() async throws {
        let server = tokenServer(refresh: .text("Blocked by firewall", status: 403))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        await #expect(throws: APIError.forbidden(message: "Blocked by firewall")) {
            try await client.send(Endpoint<OK>(.get, "/api/me"))
        }
        #expect(tokens.expiredCount == 0)
        #expect(tokens.current?.refreshToken == "refresh-1")
    }

    @Test func concurrentRetriesRejectedAfterRefreshExpireSessionOnce() async throws {
        let server = StubServer { request in
            request.url?.path() == refreshPath
                ? .json(refreshedJSON, delay: .milliseconds(100)) : .text("Unauthorized", status: 401)
        }
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        let errors = await withTaskGroup(of: APIError?.self) { group in
            for index in 0..<5 {
                group.addTask {
                    do {
                        _ = try await client.send(Endpoint<OK>(.get, "/api/items/\(index)"))
                        return nil
                    } catch {
                        return error as? APIError
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(errors == Array(repeating: .sessionExpired, count: 5))
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(tokens.expiredCount == 1)
    }

    @Test func rejectedRefreshAfterNewSignInKeepsNewSession() async throws {
        let tokens = InMemoryTokenProvider()
        let server = StubServer { request in
            if request.url?.path() == refreshPath {
                // The user signs in again while the old session's refresh is in flight.
                tokens.signIn(AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
                return .text("Unauthorized", status: 401)
            }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer access-2"
                ? .json(#"{"ok":true}"#) : .text("Unauthorized", status: 401)
        }
        let client = try makeClient(server, tokens: tokens)

        let result = try await client.send(Endpoint<OK>(.get, "/api/me"))

        #expect(result == OK(ok: true))
        #expect(tokens.expiredCount == 0)
        #expect(tokens.current == AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
    }

    @Test func rejectedRetryAfterNewSignInKeepsNewSession() async throws {
        let tokens = InMemoryTokenProvider()
        let server = StubServer { request in
            if request.url?.path() == refreshPath { return .json(refreshedJSON) }
            switch request.value(forHTTPHeaderField: "Authorization") {
            case "Bearer access-2":
                // The user signs in again before the retry's 401 is handled.
                tokens.signIn(AuthTokens(accessToken: "access-3", refreshToken: "refresh-3"))
                return .text("Unauthorized", status: 401)
            case "Bearer access-3":
                return .json(#"{"ok":true}"#)
            default:
                return .text("Unauthorized", status: 401)
            }
        }
        let client = try makeClient(server, tokens: tokens)

        let result = try await client.send(Endpoint<OK>(.get, "/api/me"))

        #expect(result == OK(ok: true))
        #expect(tokens.expiredCount == 0)
        #expect(tokens.current?.accessToken == "access-3")
    }

    @Test func signInRacingExpiryKeepsNewSession() async throws {
        let replacement = AuthTokens(accessToken: "access-2", refreshToken: "refresh-2")
        let tokens = InMemoryTokenProvider(beforeExpire: { provider in
            // Lands after the client decided to expire the old pair but before the clear.
            provider.signIn(replacement)
        })
        let server = tokenServer(refresh: .text("Unauthorized", status: 401))
        let client = try makeClient(server, tokens: tokens)

        let result = try await client.send(Endpoint<OK>(.get, "/api/me"))

        #expect(result == OK(ok: true))
        #expect(tokens.expiredCount == 0)
        #expect(tokens.current == replacement)
    }

    @Test func refreshFinishingAfterSignOutIsDiscarded() async throws {
        let server = tokenServer(refresh: .json(refreshedJSON, delay: .milliseconds(200)))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        let request = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        try await waitUntil { server.requests(path: refreshPath).count == 1 }
        tokens.signOut()

        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(tokens.current == nil)
        #expect(tokens.updates.isEmpty)
        #expect(server.requests(path: "/abs/api/me").count == 1)
    }

    @Test func refreshFinishingAfterNewSignInIsDiscarded() async throws {
        let server = tokenServer(refresh: .json(refreshedJSON, delay: .milliseconds(200)))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)
        let replacement = AuthTokens(accessToken: "access-new", refreshToken: "refresh-new")

        let request = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        try await waitUntil { server.requests(path: refreshPath).count == 1 }
        tokens.signIn(replacement)

        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(tokens.current == replacement)
        #expect(tokens.updates.isEmpty)
        #expect(server.requests(path: "/abs/api/me").count == 1)
    }

    @Test func newSessionDoesNotJoinOldSessionsRefresh() async throws {
        let replacement = AuthTokens(accessToken: "access-new", refreshToken: "refresh-new")
        let server = StubServer { request in
            if request.url?.path() == refreshPath {
                return request.value(forHTTPHeaderField: "x-refresh-token") == "refresh-new"
                    ? .json(#"{"user":{"accessToken":"access-3","refreshToken":"refresh-3"}}"#)
                    : .json(refreshedJSON, delay: .milliseconds(500))
            }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer access-3"
                ? .json(#"{"ok":true}"#) : .text("Unauthorized", status: 401)
        }
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        let old = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        try await waitUntil { server.requests(path: refreshPath).count == 1 }
        tokens.signIn(replacement)
        let result = try await client.send(Endpoint<OK>(.get, "/api/me"))

        #expect(result == OK(ok: true))
        let refreshTokens = server.requests(path: refreshPath).map { $0.value(forHTTPHeaderField: "x-refresh-token") }
        #expect(refreshTokens == ["refresh-1", "refresh-new"])
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(tokens.current == AuthTokens(accessToken: "access-3", refreshToken: "refresh-3"))
        #expect(tokens.expiredCount == 0)
    }

    @Test func unauthorizedFromStrippedHopDoesNotRefresh() async throws {
        let originHost = StubServer.uniqueHost()
        let other = StubServer { _ in .redirect(to: "https://\(originHost)/abs/final") }
        let origin = StubServer(host: originHost) { request in
            request.url?.path() == "/abs/api/me"
                ? .redirect(to: "https://\(other.host)/x") : .text("Unauthorized", status: 401)
        }
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(origin, tokens: tokens)

        await #expect(throws: APIError.unauthorized(message: "Unauthorized")) {
            try await client.send(Endpoint<OK>(.get, "/api/me"))
        }
        #expect(origin.requests(path: refreshPath).isEmpty)
        #expect(origin.requests(path: "/abs/final").first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(tokens.current == AuthTokens(accessToken: "access-1", refreshToken: "refresh-1"))
        #expect(tokens.expiredCount == 0)
    }

    @Test func unauthorizedFromStrippedHopAfterRefreshKeepsSession() async throws {
        let originHost = StubServer.uniqueHost()
        let other = StubServer { _ in .redirect(to: "https://\(originHost)/abs/final") }
        let origin = StubServer(host: originHost) { request in
            switch (request.url?.path(), request.value(forHTTPHeaderField: "Authorization")) {
            case (refreshPath, _): .json(refreshedJSON)
            case ("/abs/api/me", "Bearer access-2"): .redirect(to: "https://\(other.host)/x")
            default: .text("Unauthorized", status: 401)
            }
        }
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(origin, tokens: tokens)

        await #expect(throws: APIError.unauthorized(message: "Unauthorized")) {
            try await client.send(Endpoint<OK>(.get, "/api/me"))
        }
        #expect(origin.requests(path: refreshPath).count == 1)
        #expect(tokens.current == AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
        #expect(tokens.expiredCount == 0)
    }

    @Test func unauthorizedFromStrippedRefreshHopKeepsSession() async throws {
        let originHost = StubServer.uniqueHost()
        let other = StubServer { _ in .redirect(to: "https://\(originHost)/abs/refresh-final", status: 307) }
        let origin = StubServer(host: originHost) { request in
            request.url?.path() == refreshPath
                ? .redirect(to: "https://\(other.host)/x", status: 307) : .text("Unauthorized", status: 401)
        }
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(origin, tokens: tokens)

        await #expect(throws: APIError.unauthorized(message: "Unauthorized")) {
            try await client.send(Endpoint<OK>(.get, "/api/me"))
        }
        let final = try #require(origin.requests(path: "/abs/refresh-final").first)
        #expect(final.value(forHTTPHeaderField: "x-refresh-token") == nil)
        #expect(tokens.current == AuthTokens(accessToken: "access-1", refreshToken: "refresh-1"))
        #expect(tokens.expiredCount == 0)
    }

    @Test func replacementSessionGetsItsOwnRefreshBeforeExpiry() async throws {
        let replacement = AuthTokens(accessToken: "access-new", refreshToken: "refresh-new")
        let tokens = InMemoryTokenProvider()
        let server = StubServer { request in
            if request.url?.path() == refreshPath {
                return request.value(forHTTPHeaderField: "x-refresh-token") == "refresh-new"
                    ? .json(#"{"user":{"accessToken":"access-3","refreshToken":"refresh-3"}}"#)
                    : .text("Unauthorized", status: 401)
            }
            switch request.value(forHTTPHeaderField: "Authorization") {
            case "Bearer access-3": return .json(#"{"ok":true}"#)
            case "Bearer access-1":
                // The user signs in again while the old token is being rejected; the new access
                // token has also expired by the time it is used.
                tokens.signIn(replacement)
                return .text("Unauthorized", status: 401)
            default: return .text("Unauthorized", status: 401)
            }
        }
        let client = try makeClient(server, tokens: tokens)

        let result = try await client.send(Endpoint<OK>(.get, "/api/me"))

        #expect(result == OK(ok: true))
        let refreshTokens = server.requests(path: refreshPath).map { $0.value(forHTTPHeaderField: "x-refresh-token") }
        #expect(refreshTokens == ["refresh-new"])
        #expect(tokens.current == AuthTokens(accessToken: "access-3", refreshToken: "refresh-3"))
        #expect(tokens.expiredCount == 0)
    }

    @Test func staleSnapshotAfterFinishedRefreshDoesNotRefreshAgain() async throws {
        let server = tokenServer(refresh: .json(refreshedJSON))
        // Call 1 is the slow request's first read; call 2 is its read inside the refresh.
        let tokens = GatedTokenProvider(holdingCall: 2)
        let client = try makeClient(server, tokens: tokens)

        let slow = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        try await waitUntil { tokens.isHolding }
        let fast = try await client.send(Endpoint<OK>(.get, "/api/me"))
        tokens.release()

        #expect(fast == OK(ok: true))
        #expect(try await slow.value == OK(ok: true))
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(tokens.inner.current == AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
        #expect(tokens.inner.expiredCount == 0)
    }

    /// `/api/slow` answers 401 to `access-1` after a delay; `/api/me` is ``tokenServer(refresh:)``.
    private func delayedUnauthorizedServer() -> StubServer {
        StubServer { request in
            switch (request.url?.path(), request.value(forHTTPHeaderField: "Authorization")) {
            case (refreshPath, _): .json(refreshedJSON)
            case ("/abs/api/slow", "Bearer access-1"): .json("{}", status: 401, delay: .milliseconds(300))
            case (_, "Bearer access-2"), (_, "Bearer access-new"): .json(#"{"ok":true}"#)
            default: .text("Unauthorized", status: 401)
            }
        }
    }

    @Test func delayedUnauthorizedAfterLogoutDoesNotReuseRefresh() async throws {
        let server = delayedUnauthorizedServer()
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        let slow = Task { try await client.send(Endpoint<OK>(.get, "/api/slow")) }
        try await waitUntil { server.requests(path: "/abs/api/slow").count == 1 }
        _ = try await client.send(Endpoint<OK>(.get, "/api/me"))
        tokens.signOut()

        await #expect(throws: APIError.sessionExpired) { try await slow.value }
        #expect(server.requests(path: "/abs/api/slow").count == 1)
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(tokens.current == nil)
    }

    @Test func delayedUnauthorizedAfterNewSignInUsesNewSession() async throws {
        let server = delayedUnauthorizedServer()
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)
        let replacement = AuthTokens(accessToken: "access-new", refreshToken: "refresh-new")

        let slow = Task { try await client.send(Endpoint<OK>(.get, "/api/slow")) }
        try await waitUntil { server.requests(path: "/abs/api/slow").count == 1 }
        _ = try await client.send(Endpoint<OK>(.get, "/api/me"))
        tokens.signIn(replacement)

        #expect(try await slow.value == OK(ok: true))
        let sent = server.requests(path: "/abs/api/slow").map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(sent == ["Bearer access-1", "Bearer access-new"])
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(tokens.current == replacement)
    }

    /// The refreshed pair is rejected on send 2 (plain retry), 3 (a new sign-in during the first
    /// send needs its own refresh) or 4 (a new sign-in during the retry needs its own refresh).
    @Test(arguments: [
        (nil, 2, ["refresh-1"]), ("access-1", 3, ["refresh-new"]), ("access-2", 4, ["refresh-1", "refresh-new"]),
    ])
    func rejectedRefreshedPairExpiresSessionOnAnySend(
        signInOn trigger: String?, sends: Int, refreshedWith expectedRefreshTokens: [String]
    ) async throws {
        let replacement = AuthTokens(accessToken: "access-new", refreshToken: "refresh-new")
        let tokens = InMemoryTokenProvider()
        let server = StubServer { request in
            if request.url?.path() == refreshPath {
                return request.value(forHTTPHeaderField: "x-refresh-token") == "refresh-new"
                    ? .json(#"{"user":{"accessToken":"access-new-2","refreshToken":"refresh-new-2"}}"#)
                    : .json(refreshedJSON)
            }
            if let trigger, request.value(forHTTPHeaderField: "Authorization") == "Bearer \(trigger)" {
                tokens.signIn(replacement)
            }
            return .text("Unauthorized", status: 401)
        }
        let client = try makeClient(server, tokens: tokens)

        await #expect(throws: APIError.sessionExpired) { try await client.send(Endpoint<OK>(.get, "/api/me")) }

        #expect(server.requests(path: "/abs/api/me").count == sends)
        let refreshTokens = server.requests(path: refreshPath).map { $0.value(forHTTPHeaderField: "x-refresh-token") }
        #expect(refreshTokens == expectedRefreshTokens)
        #expect(tokens.current == nil)
        #expect(tokens.expiredCount == 1)
    }

    @Test func delayedUnauthorizedReusesRefreshThatOnlyRotatedRefreshToken() async throws {
        // Each path answers 401 to its first request and 200 afterwards.
        let seen = Mutex<Set<String>>([])
        let server = StubServer { request in
            let path = request.url?.path() ?? ""
            if path == refreshPath { return .json(#"{"user":{"accessToken":"access-1","refreshToken":"refresh-2"}}"#) }
            guard seen.withLock({ $0.insert(path).inserted }) else { return .json(#"{"ok":true}"#) }
            return path == "/abs/api/slow"
                ? .json("{}", status: 401, delay: .milliseconds(300)) : .text("Unauthorized", status: 401)
        }
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        let slow = Task { try await client.send(Endpoint<OK>(.get, "/api/slow")) }
        try await waitUntil { server.requests(path: "/abs/api/slow").count == 1 }
        _ = try await client.send(Endpoint<OK>(.get, "/api/me"))

        #expect(try await slow.value == OK(ok: true))
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(tokens.current == AuthTokens(accessToken: "access-1", refreshToken: "refresh-2"))
    }

    @Test func lineageFollowsRefreshesRecordedOutOfOrder() async throws {
        let server = StubServer { request in
            switch (request.url?.path(), request.value(forHTTPHeaderField: "x-refresh-token")) {
            case (refreshPath, "refresh-1"): return .json(refreshedJSON)
            case (refreshPath, "refresh-2"):
                return .json(#"{"user":{"accessToken":"access-3","refreshToken":"refresh-3"}}"#)
            case (refreshPath, _): return .json(#"{"user":{"accessToken":"access-4","refreshToken":"refresh-4"}}"#)
            default: break
            }
            let accepted =
                request.url?.path() == "/abs/api/other"
                && request.value(forHTTPHeaderField: "Authorization") == "Bearer access-3"
            return accepted ? .json(#"{"ok":true}"#) : .text("Unauthorized", status: 401)
        }
        let tokens = SlowFirstSwapTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        // The first request's refresh (1 -> 2) commits but returns late; meanwhile another request
        // is rejected with pair 2 and refreshes it (2 -> 3), so the edges are recorded in reverse.
        let first = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        try await waitUntil { tokens.isHolding }
        #expect(try await client.send(Endpoint<OK>(.get, "/api/other")) == OK(ok: true))
        tokens.release()

        // Pair 3 descends from pair 1, so its rejection ends the session instead of refreshing it.
        await #expect(throws: APIError.sessionExpired) { try await first.value }
        let refreshTokens = server.requests(path: refreshPath).map { $0.value(forHTTPHeaderField: "x-refresh-token") }
        #expect(refreshTokens == ["refresh-1", "refresh-2"])
        #expect(tokens.inner.current == nil)
        #expect(tokens.inner.expiredCount == 1)
    }

    @Test func refreshReturningSamePairExpiresAfterOneRetry() async throws {
        let server = StubServer { request in
            request.url?.path() == refreshPath
                ? .json(#"{"user":{"accessToken":"access-1"}}"#) : .text("Unauthorized", status: 401)
        }
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        await #expect(throws: APIError.sessionExpired) { try await client.send(Endpoint<OK>(.get, "/api/me")) }

        #expect(server.requests(path: "/abs/api/me").count == 2)
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(tokens.current == nil)
        #expect(tokens.expiredCount == 1)
    }

    @Test func cancellingRequestWaitingOnRefreshLeavesOthers() async throws {
        let server = tokenServer(refresh: .json(refreshedJSON, delay: .milliseconds(400)))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        let starter = Task { try await client.send(Endpoint<OK>(.get, "/api/items/starter")) }
        try await waitUntil { server.requests(path: refreshPath).count == 1 }
        let waiter = Task { try await client.send(Endpoint<OK>(.get, "/api/items/waiter")) }
        try await waitUntil { server.requests(path: "/abs/api/items/waiter").count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()

        #expect(try await starter.value == OK(ok: true))
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(tokens.updates == [AuthTokens(accessToken: "access-2", refreshToken: "refresh-2")])
    }

    @Test func cancellingRequestThatStartedRefreshLeavesOthers() async throws {
        let server = tokenServer(refresh: .json(refreshedJSON, delay: .milliseconds(400)))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        let starter = Task { try await client.send(Endpoint<OK>(.get, "/api/items/starter")) }
        try await waitUntil { server.requests(path: refreshPath).count == 1 }
        let waiter = Task { try await client.send(Endpoint<OK>(.get, "/api/items/waiter")) }
        try await waitUntil { server.requests(path: "/abs/api/items/waiter").count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        starter.cancel()

        await #expect(throws: CancellationError.self) { try await starter.value }
        #expect(try await waiter.value == OK(ok: true))
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(tokens.current == AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
        #expect(tokens.updates.count == 1)
    }

    @Test func concurrentRequestsExpireSessionOnce() async throws {
        let server = tokenServer(refresh: StubResponse(status: 401, delay: .milliseconds(200)))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        let errors = await withTaskGroup(of: APIError?.self) { group in
            for index in 0..<5 {
                group.addTask {
                    do {
                        _ = try await client.send(Endpoint<OK>(.get, "/api/items/\(index)"))
                        return nil
                    } catch {
                        return error as? APIError
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(errors == Array(repeating: .sessionExpired, count: 5))
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(tokens.expiredCount == 1)
    }

    @Test func serverErrorDuringRefreshKeepsSession() async throws {
        let server = tokenServer(refresh: .text("Bad Gateway", status: 502))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        await #expect(throws: APIError.http(status: 502, message: "Bad Gateway")) {
            try await client.send(Endpoint<OK>(.get, "/api/me"))
        }
        #expect(tokens.expiredCount == 0)
        #expect(tokens.current?.refreshToken == "refresh-1")
    }

    @Test func offlineDuringRefreshKeepsSession() async throws {
        let server = tokenServer(refresh: .failure(.notConnectedToInternet))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        await #expect(throws: APIError.network(.notConnectedToInternet)) {
            try await client.send(Endpoint<OK>(.get, "/api/me"))
        }
        #expect(tokens.expiredCount == 0)
    }

    @Test func unauthorizedAfterRefreshExpiresSession() async throws {
        let server = StubServer { request in
            request.url?.path() == refreshPath ? .json(refreshedJSON) : .text("Unauthorized", status: 401)
        }
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        await #expect(throws: APIError.sessionExpired) {
            try await client.send(Endpoint<OK>(.get, "/api/me"))
        }
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(server.requests(path: "/abs/api/me").count == 2)
        #expect(tokens.expiredCount == 1)
    }

    @Test func requestUsingStaleTokenRetriesWithoutRefreshing() async throws {
        let server = tokenServer(refresh: .json(refreshedJSON))
        let client = try makeClient(server, tokens: RotatedTokenProvider())

        let result = try await client.send(Endpoint<OK>(.get, "/api/me"))

        #expect(result == OK(ok: true))
        #expect(server.requests(path: refreshPath).isEmpty)
        #expect(
            server.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
                "Bearer access-1", "Bearer access-2",
            ])
    }

    @Test func unauthenticatedEndpointNeverRefreshes() async throws {
        let server = tokenServer(refresh: .json(refreshedJSON))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        await #expect(throws: APIError.unauthorized(message: "Unauthorized")) {
            try await client.send(Endpoint<EmptyResponse>(.post, "/login", requiresAuthentication: false))
        }
        #expect(server.requests(path: refreshPath).isEmpty)
        #expect(tokens.expiredCount == 0)
    }

    @Test func malformedRefreshResponseIsDecodingError() async throws {
        let server = tokenServer(refresh: .json(#"{"user":{}}"#))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        await #expect {
            try await client.send(Endpoint<OK>(.get, "/api/me"))
        } throws: { error in
            guard case .decoding = error as? APIError else { return false }
            return true
        }
        #expect(tokens.expiredCount == 0)
    }
}

/// Polls `condition` every 10 ms for up to two seconds.
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for condition")
}
