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

/// Wraps an ``InMemoryTokenProvider`` and holds the `heldCall`th `tokens()` call until
/// ``release()``, after taking its snapshot (or before, with `readsAfterRelease`). ``held()``
/// returns once that call is holding. `heldCall: 0` never holds.
private final class GatedTokenProvider: TokenProvider {
    let inner = InMemoryTokenProvider()
    private let heldCall: Int
    private let readsAfterRelease: Bool
    private let calls = Mutex(0)
    private let holding = Checkpoint()
    private let released = Checkpoint()

    init(holdingCall heldCall: Int, readsAfterRelease: Bool = false) {
        self.heldCall = heldCall
        self.readsAfterRelease = readsAfterRelease
    }

    func held() async {
        await holding.reached()
    }

    func release() {
        released.pass()
    }

    func tokens() async -> AuthTokens? {
        let call = calls.withLock {
            $0 += 1
            return $0
        }
        guard call == heldCall else { return await inner.tokens() }
        let snapshot = readsAfterRelease ? nil : await inner.tokens()
        holding.pass()
        await released.reached()
        return readsAfterRelease ? await inner.tokens() : snapshot
    }

    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool {
        await inner.replaceTokens(expected: expected, with: new)
    }

    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool {
        await inner.expireSession(ifCurrent: rejected)
    }
}

/// Wraps an ``InMemoryTokenProvider`` and, after committing its `heldSwap`th successful swap
/// (the first by default), waits for ``release()`` before returning, so other work can happen
/// between the commit and the return. ``held()`` returns once that swap is holding.
private final class SlowSwapTokenProvider: TokenProvider {
    let inner = InMemoryTokenProvider()
    private let heldSwap: Int
    private let swaps = Mutex(0)
    private let holding = Checkpoint()
    private let released = Checkpoint()

    init(holdingSwap heldSwap: Int = 1) {
        self.heldSwap = heldSwap
    }

    func held() async {
        await holding.reached()
    }

    func release() {
        released.pass()
    }

    func tokens() async -> AuthTokens? {
        await inner.tokens()
    }

    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool {
        guard await inner.replaceTokens(expected: expected, with: new) else { return false }
        let swap = swaps.withLock {
            $0 += 1
            return $0
        }
        if swap == heldSwap {
            holding.pass()
            await released.reached()
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

    /// A request whose 401 a refresh answered reports it; one sent with tokens the server accepts
    /// doesn't.
    @Test(arguments: [true, false])
    func trackedRequestReportsItsOwnRefresh(rejected: Bool) async throws {
        let server = tokenServer(refresh: .json(refreshedJSON))
        let tokens = InMemoryTokenProvider(
            AuthTokens(accessToken: rejected ? "access-1" : "access-2", refreshToken: "refresh-1"))
        let client = try makeClient(server, tokens: tokens)

        let tracked = await client.sendTrackingRefresh(Endpoint<OK>(.get, "/api/me"))

        #expect(try tracked.result.get() == OK(ok: true))
        #expect(tracked.didRefresh == rejected)
        #expect(server.requests(path: refreshPath).count == (rejected ? 1 : 0))
    }

    /// The refresh is reported even when the retried request then fails.
    @Test func trackedRequestReportsARefreshBeforeItsFailure() async throws {
        let server = StubServer { request in
            if request.url?.path() == refreshPath { return .json(refreshedJSON) }
            let refreshed = request.value(forHTTPHeaderField: "Authorization") == "Bearer access-2"
            return .text(refreshed ? "Not Found" : "Unauthorized", status: refreshed ? 404 : 401)
        }
        let client = try makeClient(server, tokens: InMemoryTokenProvider())

        let tracked = await client.sendTrackingRefresh(Endpoint<OK>(.get, "/api/session/s"))

        #expect(throws: APIError.notFound) { try tracked.result.get() }
        #expect(tracked.didRefresh)
    }

    /// Another request's refresh while this one is in flight isn't this one's, though its tokens
    /// changed meanwhile (comparing them before and after would say otherwise).
    @Test func anotherRequestsRefreshIsNotTracked() async throws {
        let server = tokenServer(refresh: .json(refreshedJSON))
        // Call 1 is the tracked request's token read, held until the other request has refreshed.
        let tokens = GatedTokenProvider(holdingCall: 1, readsAfterRelease: true)
        let client = try makeClient(server, tokens: tokens)

        let tracked = Task { await client.sendTrackingRefresh(Endpoint<OK>(.get, "/api/me")) }
        await tokens.held()
        let other = await client.sendTrackingRefresh(Endpoint<OK>(.get, "/api/other"))
        tokens.release()
        let result = await tracked.value

        // Control: the other request did refresh.
        #expect(other.didRefresh)
        #expect(try result.result.get() == OK(ok: true))
        #expect(!result.didRefresh)
        #expect(server.requests(path: refreshPath).count == 1)
    }

    @Test func keepsRefreshTokenWhenResponseOmitsIt() async throws {
        let server = tokenServer(refresh: .json(#"{"user":{"accessToken":"access-2"}}"#))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        _ = try await client.send(Endpoint<OK>(.get, "/api/me"))

        #expect(tokens.current == AuthTokens(accessToken: "access-2", refreshToken: "refresh-1"))
    }

    @Test func concurrentUnauthorizedRequestsShareOneRefresh() async throws {
        let refreshGate = StubGate()
        let server = tokenServer(refresh: .json(refreshedJSON, gate: refreshGate))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)
        let joins = Checkpoint()
        await client.observeRefreshJoins { joins.pass() }

        let results = try await withThrowingTaskGroup(of: OK.self) { group in
            for index in 0..<8 {
                group.addTask { try await client.send(Endpoint<OK>(.get, "/api/items/\(index)")) }
            }
            // One request starts the refresh; the other seven wait for it before it finishes.
            await refreshGate.arrived()
            await joins.reached(7)
            refreshGate.open()
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(results.count == 8)
        let rejected = server.requests.filter { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-1" }
        #expect(rejected.count == 8)
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
        let refreshGate = StubGate()
        let server = StubServer { request in
            request.url?.path() == refreshPath
                ? .json(refreshedJSON, gate: refreshGate) : .text("Unauthorized", status: 401)
        }
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)
        let joins = Checkpoint()
        await client.observeRefreshJoins { joins.pass() }

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
            await refreshGate.arrived()
            await joins.reached(4)
            refreshGate.open()
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
        let refreshGate = StubGate()
        let server = tokenServer(refresh: .json(refreshedJSON, gate: refreshGate))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        let request = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        await refreshGate.arrived()
        tokens.signOut()
        refreshGate.open()

        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(tokens.current == nil)
        #expect(tokens.updates.isEmpty)
        #expect(server.requests(path: "/abs/api/me").count == 1)
    }

    @Test func refreshFinishingAfterNewSignInIsDiscarded() async throws {
        let refreshGate = StubGate()
        let server = tokenServer(refresh: .json(refreshedJSON, gate: refreshGate))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)
        let replacement = AuthTokens(accessToken: "access-new", refreshToken: "refresh-new")

        let request = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        await refreshGate.arrived()
        tokens.signIn(replacement)
        refreshGate.open()

        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(tokens.current == replacement)
        #expect(tokens.updates.isEmpty)
        #expect(server.requests(path: "/abs/api/me").count == 1)
    }

    @Test func newSessionDoesNotJoinOldSessionsRefresh() async throws {
        let replacement = AuthTokens(accessToken: "access-new", refreshToken: "refresh-new")
        let oldRefreshGate = StubGate()
        let server = StubServer { request in
            if request.url?.path() == refreshPath {
                return request.value(forHTTPHeaderField: "x-refresh-token") == "refresh-new"
                    ? .json(#"{"user":{"accessToken":"access-3","refreshToken":"refresh-3"}}"#)
                    : .json(refreshedJSON, gate: oldRefreshGate)
            }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer access-3"
                ? .json(#"{"ok":true}"#) : .text("Unauthorized", status: 401)
        }
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        let old = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        await oldRefreshGate.arrived()
        tokens.signIn(replacement)
        let result = try await client.send(Endpoint<OK>(.get, "/api/me"))
        oldRefreshGate.open()

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

    /// A refresh redirected off the origin is refused before the other host is contacted, whatever
    /// that host would answer (a 401, or tokens of its own).
    @Test(arguments: [
        StubResponse.text("Unauthorized", status: 401),
        .json(#"{"user":{"accessToken":"access-evil","refreshToken":"refresh-evil"}}"#),
    ])
    func crossOriginRefreshRedirectIsRefused(otherResponse: StubResponse) async throws {
        let other = StubServer { _ in otherResponse }
        let origin = StubServer { request in
            request.url?.path() == refreshPath
                ? .redirect(to: "https://\(other.host)/x", status: 307) : .text("Unauthorized", status: 401)
        }
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(origin, tokens: tokens)

        await #expect(throws: APIError.redirectRefused(status: 307)) {
            try await client.send(Endpoint<OK>(.get, "/api/me"))
        }
        #expect(other.requests.isEmpty)
        #expect(origin.requests(path: "/abs/api/me").count == 1)
        #expect(tokens.current == AuthTokens(accessToken: "access-1", refreshToken: "refresh-1"))
        #expect(tokens.updates.isEmpty)
        #expect(tokens.expiredCount == 0)
    }

    @Test func sameOriginRefreshRedirectIsFollowed() async throws {
        let server = StubServer { request in
            switch (request.url?.path(), request.value(forHTTPHeaderField: "Authorization")) {
            case (refreshPath, _):
                .redirect(to: "https://\(request.url?.host() ?? "")/abs/auth/refresh-v2", status: 307)
            case ("/abs/auth/refresh-v2", _): .json(refreshedJSON)
            case (_, "Bearer access-2"): .json(#"{"ok":true}"#)
            default: .text("Unauthorized", status: 401)
            }
        }
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        #expect(try await client.send(Endpoint<OK>(.get, "/api/me")) == OK(ok: true))
        let followed = try #require(server.requests(path: "/abs/auth/refresh-v2").first)
        #expect(followed.httpMethod == "POST")
        #expect(followed.value(forHTTPHeaderField: "x-refresh-token") == "refresh-1")
        #expect(tokens.current == AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
    }

    @Test func refreshBetweenTokenReadAndSendCountsAsThisRequestsRefresh() async throws {
        let server = StubServer { request in
            switch (request.url?.path(), request.value(forHTTPHeaderField: "x-refresh-token")) {
            case (refreshPath, "refresh-1"): return .json(refreshedJSON)
            case (refreshPath, _): return .json(#"{"user":{"accessToken":"access-3","refreshToken":"refresh-3"}}"#)
            default: break
            }
            let accepted =
                request.url?.path() == "/abs/api/other"
                && request.value(forHTTPHeaderField: "Authorization") == "Bearer access-2"
            return accepted ? .json(#"{"ok":true}"#) : .text("Unauthorized", status: 401)
        }
        // Read 1 is the first request's initial read: it returns pair 1 but is held while another
        // request refreshes pair 1 to pair 2, so the first request sends pair 1 after that refresh.
        let tokens = GatedTokenProvider(holdingCall: 1)
        let client = try makeClient(server, tokens: tokens)

        let first = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        await tokens.held()
        #expect(try await client.send(Endpoint<OK>(.get, "/api/other")) == OK(ok: true))
        tokens.release()

        // The refresh to pair 2 counts for the first request too, so pair 2 being rejected ends
        // the session instead of refreshing again.
        await #expect(throws: APIError.sessionExpired) { try await first.value }
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(server.requests(path: "/abs/api/me").count == 2)
        #expect(tokens.inner.current == nil)
        #expect(tokens.inner.expiredCount == 1)
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
        await tokens.held()
        let fast = try await client.send(Endpoint<OK>(.get, "/api/me"))
        tokens.release()

        #expect(fast == OK(ok: true))
        #expect(try await slow.value == OK(ok: true))
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(tokens.inner.current == AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
        #expect(tokens.inner.expiredCount == 0)
    }

    /// `/api/slow` answers 401 to `access-1` once `slowGate` opens; `/api/me` is
    /// ``tokenServer(refresh:)``.
    private func delayedUnauthorizedServer(slowGate: StubGate) -> StubServer {
        StubServer { request in
            switch (request.url?.path(), request.value(forHTTPHeaderField: "Authorization")) {
            case (refreshPath, _): .json(refreshedJSON)
            case ("/abs/api/slow", "Bearer access-1"): .json("{}", status: 401, gate: slowGate)
            case (_, "Bearer access-2"), (_, "Bearer access-new"): .json(#"{"ok":true}"#)
            default: .text("Unauthorized", status: 401)
            }
        }
    }

    @Test func delayedUnauthorizedAfterLogoutDoesNotReuseRefresh() async throws {
        let slowGate = StubGate()
        let server = delayedUnauthorizedServer(slowGate: slowGate)
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        let slow = Task { try await client.send(Endpoint<OK>(.get, "/api/slow")) }
        await slowGate.arrived()
        _ = try await client.send(Endpoint<OK>(.get, "/api/me"))
        tokens.signOut()
        slowGate.open()

        await #expect(throws: APIError.sessionExpired) { try await slow.value }
        #expect(server.requests(path: "/abs/api/slow").count == 1)
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(tokens.current == nil)
    }

    @Test func delayedUnauthorizedAfterNewSignInUsesNewSession() async throws {
        let slowGate = StubGate()
        let server = delayedUnauthorizedServer(slowGate: slowGate)
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)
        let replacement = AuthTokens(accessToken: "access-new", refreshToken: "refresh-new")

        let slow = Task { try await client.send(Endpoint<OK>(.get, "/api/slow")) }
        await slowGate.arrived()
        _ = try await client.send(Endpoint<OK>(.get, "/api/me"))
        tokens.signIn(replacement)
        slowGate.open()

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
        let slowGate = StubGate()
        let server = StubServer { request in
            let path = request.url?.path() ?? ""
            if path == refreshPath { return .json(#"{"user":{"accessToken":"access-1","refreshToken":"refresh-2"}}"#) }
            guard seen.withLock({ $0.insert(path).inserted }) else { return .json(#"{"ok":true}"#) }
            return path == "/abs/api/slow"
                ? .json("{}", status: 401, gate: slowGate) : .text("Unauthorized", status: 401)
        }
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        let slow = Task { try await client.send(Endpoint<OK>(.get, "/api/slow")) }
        await slowGate.arrived()
        _ = try await client.send(Endpoint<OK>(.get, "/api/me"))
        slowGate.open()

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
        let tokens = SlowSwapTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        // The first request's refresh (1 -> 2) commits but returns late; meanwhile another request
        // is rejected with pair 2 and refreshes it (2 -> 3), so the edges are recorded in reverse.
        let first = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        await tokens.held()
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

    /// With `gatesPostRefreshRead`, the first request's token read after its refresh is held while
    /// the second request runs, so the finished flight must not still be joinable.
    @Test(arguments: [false, true])
    func laterUnauthorizedAfterSamePairRefreshRefreshesAgain(gatesPostRefreshRead: Bool) async throws {
        // The refresh always returns the same pair. `/api/me` works after one refresh and
        // `/api/other` only after a second one.
        let refreshes = Mutex(0)
        let server = StubServer { request in
            switch request.url?.path() {
            case refreshPath:
                refreshes.withLock { $0 += 1 }
                return .json(#"{"user":{"accessToken":"access-1"}}"#)
            case "/abs/api/me" where refreshes.withLock({ $0 >= 1 }),
                "/abs/api/other" where refreshes.withLock({ $0 >= 2 }):
                return .json(#"{"ok":true}"#)
            default:
                return .text("Unauthorized", status: 401)
            }
        }
        // Reads 1 and 2 are the first request's initial and pre-refresh reads; read 3 follows
        // its refresh.
        let tokens = GatedTokenProvider(holdingCall: gatesPostRefreshRead ? 3 : 0)
        let client = try makeClient(server, tokens: tokens)

        let first = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        if gatesPostRefreshRead {
            await tokens.held()
        } else {
            #expect(try await first.value == OK(ok: true))
        }
        #expect(try await client.send(Endpoint<OK>(.get, "/api/other")) == OK(ok: true))
        tokens.release()
        #expect(try await first.value == OK(ok: true))

        #expect(server.requests(path: refreshPath).count == 2)
        #expect(tokens.inner.current == AuthTokens(accessToken: "access-1", refreshToken: "refresh-1"))
        #expect(tokens.inner.expiredCount == 0)
    }

    // MARK: Refresh lineage across concurrent requests

    /// Refresh tokens 1 -> 2 -> 3 -> 4; access tokens follow. `/api/slow` answers once `slowGate`
    /// opens.
    private func lineageServer(
        slowGate: StubGate, accepts: @escaping @Sendable (String?, String?) -> Bool
    ) -> StubServer {
        StubServer { request in
            let path = request.url?.path()
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            if path == refreshPath {
                let generation = Int(request.value(forHTTPHeaderField: "x-refresh-token")?.dropFirst(8) ?? "") ?? 0
                let next = generation + 1
                return .json(#"{"user":{"accessToken":"access-\#(next)","refreshToken":"refresh-\#(next)"}}"#)
            }
            let gate = path == "/abs/api/slow" ? slowGate : nil
            return accepts(path, authorization)
                ? .json(#"{"ok":true}"#, gate: gate) : .json("{}", status: 401, gate: gate)
        }
    }

    /// (a) A request sent with pair 1 whose 401 arrives after another request refreshed 1 -> 2
    /// retries with pair 2 without refreshing again.
    @Test func lateUnauthorizedRetriesWithOtherRequestsRefresh() async throws {
        let slowGate = StubGate()
        let server = lineageServer(slowGate: slowGate) { _, authorization in authorization == "Bearer access-2" }
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        let late = Task { try await client.send(Endpoint<OK>(.get, "/api/slow")) }
        await slowGate.arrived()
        #expect(try await client.send(Endpoint<OK>(.get, "/api/me")) == OK(ok: true))
        slowGate.open()

        #expect(try await late.value == OK(ok: true))
        let sent = server.requests(path: "/abs/api/slow").map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(sent == ["Bearer access-1", "Bearer access-2"])
        #expect(server.requests(path: refreshPath).count == 1)
    }

    /// (a') If pair 2 is then rejected too, the late request ends the session: pair 2 came from a
    /// refresh after it read pair 1.
    @Test func lateUnauthorizedThenRejectedRefreshExpires() async throws {
        let slowGate = StubGate()
        let server = lineageServer(slowGate: slowGate) { path, authorization in
            path == "/abs/api/me" && authorization == "Bearer access-2"
        }
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        let late = Task { try await client.send(Endpoint<OK>(.get, "/api/slow")) }
        await slowGate.arrived()
        #expect(try await client.send(Endpoint<OK>(.get, "/api/me")) == OK(ok: true))
        slowGate.open()

        await #expect(throws: APIError.sessionExpired) { try await late.value }
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(tokens.expiredCount == 1)
    }

    /// (b) A request refreshes 1 -> 2 and its retry with pair 2 is slow to be rejected; meanwhile
    /// another request refreshes 2 -> 3. Pair 3 descends from this request's refresh, so its
    /// rejection ends the session instead of refreshing 3 -> 4.
    @Test func lineageSurvivesAnotherRefreshDuringRetry() async throws {
        let retryGate = StubGate()
        let server = StubServer { request in
            let path = request.url?.path()
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            if path == refreshPath {
                let generation = Int(request.value(forHTTPHeaderField: "x-refresh-token")?.dropFirst(8) ?? "") ?? 0
                let next = generation + 1
                return .json(#"{"user":{"accessToken":"access-\#(next)","refreshToken":"refresh-\#(next)"}}"#)
            }
            if path == "/abs/api/other", authorization == "Bearer access-3" { return .json(#"{"ok":true}"#) }
            let gate = path == "/abs/api/me" && authorization == "Bearer access-2" ? retryGate : nil
            return .json("{}", status: 401, gate: gate)
        }
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        let first = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        await retryGate.arrived()
        #expect(try await client.send(Endpoint<OK>(.get, "/api/other")) == OK(ok: true))
        retryGate.open()

        await #expect(throws: APIError.sessionExpired) { try await first.value }
        let refreshTokens = server.requests(path: refreshPath).map { $0.value(forHTTPHeaderField: "x-refresh-token") }
        #expect(refreshTokens == ["refresh-1", "refresh-2"])
        let sent = server.requests(path: "/abs/api/me").map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(sent == ["Bearer access-1", "Bearer access-2", "Bearer access-3"])
        #expect(tokens.current == nil)
        #expect(tokens.expiredCount == 1)
    }

    /// A request's retry with its refreshed pair 2 is rejected while another request's refresh of
    /// pair 2 is in flight: (a) before the provider swaps 2 -> 3, or (b) after the swap but before
    /// it returns. The rejection waits for that refresh instead of expiring the session (which
    /// would discard it) and retries once with pair 3. Pair 3 descends from this request's refresh,
    /// so if it is rejected too the session expires without a third refresh.
    @Test(arguments: [false, true], [true, false])
    func retryRejectedDuringOtherRefreshOfRefreshedPairWaitsForIt(
        swapCommitted: Bool, retryAccepted: Bool
    ) async throws {
        let refreshGate = StubGate()  // (a): holds the 2 -> 3 refresh response
        let retryGate = StubGate()  // holds the 401 for the retry with pair 2
        let finalGate = StubGate()  // holds the answer for the retry with pair 3
        let server = StubServer { request in
            let path = request.url?.path()
            if path == refreshPath {
                let generation = Int(request.value(forHTTPHeaderField: "x-refresh-token")?.dropFirst(8) ?? "") ?? 0
                let next = generation + 1
                return .json(
                    #"{"user":{"accessToken":"access-\#(next)","refreshToken":"refresh-\#(next)"}}"#,
                    gate: generation == 2 && !swapCommitted ? refreshGate : nil)
            }
            switch (path, request.value(forHTTPHeaderField: "Authorization")) {
            case ("/abs/api/me", "Bearer access-2"):
                return .json("{}", status: 401, gate: retryGate)
            case ("/abs/api/me", "Bearer access-3"):
                return retryAccepted
                    ? .json(#"{"ok":true}"#, gate: finalGate) : .json("{}", status: 401, gate: finalGate)
            case ("/abs/api/other", "Bearer access-3"):
                return .json(#"{"ok":true}"#)
            default:
                return .json("{}", status: 401)
            }
        }
        // Swap 1 is the first request's 1 -> 2; (b) holds swap 2 (2 -> 3) after committing it.
        let tokens = SlowSwapTokenProvider(holdingSwap: swapCommitted ? 2 : 0)
        let client = try makeClient(server, tokens: tokens)
        // Passes once the first request has handled its retry's 401: it joined the refresh, or
        // (without waiting for it) finished or sent its next retry.
        let handled = Checkpoint()
        await client.observeRefreshJoins { handled.pass() }

        let first = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        await retryGate.arrived()
        let other = Task { try await client.send(Endpoint<OK>(.get, "/api/other")) }
        if swapCommitted { await tokens.held() } else { await refreshGate.arrived() }
        Task {
            _ = await first.result
            handled.pass()
        }
        Task {
            await finalGate.arrived()
            handled.pass()
        }
        retryGate.open()
        await handled.reached()
        if swapCommitted { tokens.release() } else { refreshGate.open() }
        #expect(try await other.value == OK(ok: true))
        finalGate.open()

        if retryAccepted {
            #expect(try await first.value == OK(ok: true))
            #expect(tokens.inner.current == AuthTokens(accessToken: "access-3", refreshToken: "refresh-3"))
            #expect(tokens.inner.expiredCount == 0)
        } else {
            await #expect(throws: APIError.sessionExpired) { try await first.value }
            #expect(tokens.inner.current == nil)
            #expect(tokens.inner.expiredCount == 1)
        }
        let refreshTokens = server.requests(path: refreshPath).map { $0.value(forHTTPHeaderField: "x-refresh-token") }
        #expect(refreshTokens == ["refresh-1", "refresh-2"])
        let sent = server.requests(path: "/abs/api/me").map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(sent == ["Bearer access-1", "Bearer access-2", "Bearer access-3"])
    }

    /// As above, but the other request's refresh returns pair 2 unchanged. It completed after the
    /// rejected send, so it answers that rejection: the request retries with pair 2 once instead
    /// of ending the session the other request just refreshed.
    @Test func retryRejectedDuringOtherSamePairRefreshRetriesOnce() async throws {
        let refreshes = Mutex(0)
        let refreshGate = StubGate()
        let retryGate = StubGate()
        let server = StubServer { request in
            let path = request.url?.path()
            if path == refreshPath {
                refreshes.withLock { $0 += 1 }
                return request.value(forHTTPHeaderField: "x-refresh-token") == "refresh-1"
                    ? .json(refreshedJSON) : .json(#"{"user":{"accessToken":"access-2"}}"#, gate: refreshGate)
            }
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer access-2" else {
                return .json("{}", status: 401)
            }
            if refreshes.withLock({ $0 >= 2 }) { return .json(#"{"ok":true}"#) }
            return .json("{}", status: 401, gate: path == "/abs/api/me" ? retryGate : nil)
        }
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)
        let handled = Checkpoint()
        await client.observeRefreshJoins { handled.pass() }

        let first = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        await retryGate.arrived()
        let other = Task { try await client.send(Endpoint<OK>(.get, "/api/other")) }
        await refreshGate.arrived()
        Task {
            _ = await first.result
            handled.pass()
        }
        retryGate.open()
        await handled.reached()
        refreshGate.open()

        #expect(try await other.value == OK(ok: true))
        #expect(try await first.value == OK(ok: true))
        #expect(refreshes.withLock { $0 } == 2)
        let sent = server.requests(path: "/abs/api/me").map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(sent == ["Bearer access-1", "Bearer access-2", "Bearer access-2"])
        #expect(tokens.current == AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
        #expect(tokens.expiredCount == 0)
    }

    /// (c) The request that started a refresh is cancelled while it waits; the refresh still
    /// completes, and a request whose 401 arrives afterwards uses it, then expires when the
    /// refreshed pair is rejected.
    @Test func cancelledRefreshStarterKeepsLineageForOthers() async throws {
        let refreshGate = StubGate()
        let slowGate = StubGate()
        let server = StubServer { request in
            switch request.url?.path() {
            case refreshPath: .json(refreshedJSON, gate: refreshGate)
            case "/abs/api/slow": .json("{}", status: 401, gate: slowGate)
            default: .text("Unauthorized", status: 401)
            }
        }
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        let late = Task { try await client.send(Endpoint<OK>(.get, "/api/slow")) }
        await slowGate.arrived()
        let starter = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        await refreshGate.arrived()
        starter.cancel()
        refreshGate.open()

        await #expect(throws: CancellationError.self) { try await starter.value }
        slowGate.open()
        await #expect(throws: APIError.sessionExpired) { try await late.value }
        #expect(server.requests(path: refreshPath).count == 1)
        let sent = server.requests(path: "/abs/api/slow").map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(sent == ["Bearer access-1", "Bearer access-2"])
        #expect(tokens.updates == [AuthTokens(accessToken: "access-2", refreshToken: "refresh-2")])
        #expect(tokens.expiredCount == 1)
    }

    /// (c) Two refreshes in flight for different sessions: the old session's refresh is
    /// discarded, the new session's refresh is this request's, and its rejection expires.
    @Test func concurrentRefreshesOfDifferentSessionsKeepSeparateLineage() async throws {
        let replacement = AuthTokens(accessToken: "access-new", refreshToken: "refresh-new")
        let oldRefreshGate = StubGate()
        let server = StubServer { request in
            guard request.url?.path() == refreshPath else { return .text("Unauthorized", status: 401) }
            return request.value(forHTTPHeaderField: "x-refresh-token") == "refresh-new"
                ? .json(#"{"user":{"accessToken":"access-new-2","refreshToken":"refresh-new-2"}}"#)
                : .json(refreshedJSON, gate: oldRefreshGate)
        }
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)

        let old = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        await oldRefreshGate.arrived()
        tokens.signIn(replacement)
        await #expect(throws: APIError.sessionExpired) { try await client.send(Endpoint<OK>(.get, "/api/other")) }
        oldRefreshGate.open()

        await #expect(throws: CancellationError.self) { try await old.value }
        let refreshTokens = server.requests(path: refreshPath).map { $0.value(forHTTPHeaderField: "x-refresh-token") }
        #expect(refreshTokens == ["refresh-1", "refresh-new"])
        #expect(tokens.current == nil)
        #expect(tokens.expiredCount == 1)
    }

    // MARK: Refresh history retention

    /// A request that read pair 1 holds its stale snapshot while ten other requests each refresh
    /// the session once (1 -> 2 -> ... -> 11), more refreshes than any fixed history would keep.
    /// Its late 401 must still see that pair 11 descends from pair 1: it retries with pair 11
    /// without refreshing again, and if pair 11 is rejected too the session expires.
    @Test(arguments: [true, false])
    func lateUnauthorizedAfterManyRefreshesKeepsLineage(lateRetryAccepted: Bool) async throws {
        let steps = 10
        let server = StubServer { request in
            let path = request.url?.path() ?? ""
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            if path == refreshPath {
                let generation = Int(request.value(forHTTPHeaderField: "x-refresh-token")?.dropFirst(8) ?? "") ?? 0
                let next = generation + 1
                return .json(#"{"user":{"accessToken":"access-\#(next)","refreshToken":"refresh-\#(next)"}}"#)
            }
            // `/api/step/k` rejects only pair k, so each step refreshes exactly once and succeeds.
            if path.hasPrefix("/abs/api/step/") {
                let step = path.dropFirst("/abs/api/step/".count)
                return authorization == "Bearer access-\(step)" ? .json("{}", status: 401) : .json(#"{"ok":true}"#)
            }
            let accepted = lateRetryAccepted && authorization != "Bearer access-1"
            return accepted ? .json(#"{"ok":true}"#) : .json("{}", status: 401)
        }
        // Call 1 is the late request's token read; call 2 is its read after the 401, held with
        // the stale pair 1 while the steps run.
        let tokens = GatedTokenProvider(holdingCall: 2)
        let client = try makeClient(server, tokens: tokens)

        let late = Task { try await client.send(Endpoint<OK>(.get, "/api/late")) }
        await tokens.held()
        for step in 1...steps {
            #expect(try await client.send(Endpoint<OK>(.get, "/api/step/\(step)")) == OK(ok: true))
        }
        tokens.release()

        if lateRetryAccepted {
            #expect(try await late.value == OK(ok: true))
            #expect(tokens.inner.current?.accessToken == "access-\(steps + 1)")
        } else {
            await #expect(throws: APIError.sessionExpired) { try await late.value }
            #expect(tokens.inner.current == nil)
            #expect(tokens.inner.expiredCount == 1)
        }
        let sent = server.requests(path: "/abs/api/late").map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(sent == ["Bearer access-1", "Bearer access-\(steps + 1)"])
        #expect(server.requests(path: refreshPath).count == steps)
    }

    // MARK: Lineage timing

    /// A refresh completes after a request captured its generation but before its token read, so
    /// it reads the refreshed pair. That pair was never rejected for this request: its 401 gets
    /// its own refresh rather than ending the session.
    @Test func refreshBeforeTokenReadIsNotThisRequestsRefresh() async throws {
        let server = StubServer { request in
            let path = request.url?.path()
            if path == refreshPath {
                return request.value(forHTTPHeaderField: "x-refresh-token") == "refresh-1"
                    ? .json(refreshedJSON) : .json(#"{"user":{"accessToken":"access-3","refreshToken":"refresh-3"}}"#)
            }
            let accepted: Set<String> = path == "/abs/api/other" ? ["Bearer access-2"] : ["Bearer access-3"]
            return accepted.contains(request.value(forHTTPHeaderField: "Authorization") ?? "")
                ? .json(#"{"ok":true}"#) : .text("Unauthorized", status: 401)
        }
        // Call 1 is the first request's initial read, held before it reads anything.
        let tokens = GatedTokenProvider(holdingCall: 1, readsAfterRelease: true)
        let client = try makeClient(server, tokens: tokens)

        let first = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        await tokens.held()
        #expect(try await client.send(Endpoint<OK>(.get, "/api/other")) == OK(ok: true))
        tokens.release()

        #expect(try await first.value == OK(ok: true))
        let sent = server.requests(path: "/abs/api/me").map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(sent == ["Bearer access-2", "Bearer access-3"])
        let refreshTokens = server.requests(path: refreshPath).map { $0.value(forHTTPHeaderField: "x-refresh-token") }
        #expect(refreshTokens == ["refresh-1", "refresh-2"])
        #expect(tokens.inner.expiredCount == 0)
    }

    /// A refresh that returns the same pair completes after a request captured its generation but
    /// before its token read. The request then sends that pair; the refresh happened before the
    /// send, so it doesn't answer this 401. The request must try the refresh token itself instead
    /// of retrying once and ending the session.
    @Test func samePairRefreshBeforeSendIsNotThisRequestsRefresh() async throws {
        // The refresh always returns the same pair. `/api/other` works after one refresh and
        // `/api/me` only after a second one.
        let refreshes = Mutex(0)
        let server = StubServer { request in
            switch request.url?.path() {
            case refreshPath:
                refreshes.withLock { $0 += 1 }
                return .json(#"{"user":{"accessToken":"access-1"}}"#)
            case "/abs/api/other" where refreshes.withLock({ $0 >= 1 }),
                "/abs/api/me" where refreshes.withLock({ $0 >= 2 }):
                return .json(#"{"ok":true}"#)
            default:
                return .text("Unauthorized", status: 401)
            }
        }
        // Call 1 is the first request's initial read, held before it reads anything.
        let tokens = GatedTokenProvider(holdingCall: 1, readsAfterRelease: true)
        let client = try makeClient(server, tokens: tokens)

        let first = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        await tokens.held()
        #expect(try await client.send(Endpoint<OK>(.get, "/api/other")) == OK(ok: true))
        tokens.release()

        #expect(try await first.value == OK(ok: true))
        #expect(server.requests(path: "/abs/api/me").count == 2)
        #expect(server.requests(path: refreshPath).count == 2)
        #expect(tokens.inner.current == AuthTokens(accessToken: "access-1", refreshToken: "refresh-1"))
        #expect(tokens.inner.expiredCount == 0)
    }

    /// A refresh fails while another request holds the pre-refresh pair. Nothing was refreshed,
    /// so that request's 401 starts its own refresh (a server error keeps the session), or ends
    /// the session if the refresh token was rejected.
    @Test(arguments: [false, true])
    func failedRefreshWhileOtherRequestHoldsOldPair(refreshTokenRejected: Bool) async throws {
        let refreshCalls = Mutex(0)
        let server = StubServer { request in
            if request.url?.path() == refreshPath {
                let call = refreshCalls.withLock {
                    $0 += 1
                    return $0
                }
                if refreshTokenRejected { return .text("Unauthorized", status: 401) }
                return call == 1 ? .text("Unavailable", status: 503) : .json(refreshedJSON)
            }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer access-2"
                ? .json(#"{"ok":true}"#) : .text("Unauthorized", status: 401)
        }
        // Call 2 is the held request's read after its 401: it keeps pair 1 while the other
        // request's refresh fails.
        let tokens = GatedTokenProvider(holdingCall: 2)
        let client = try makeClient(server, tokens: tokens)

        let held = Task { try await client.send(Endpoint<OK>(.get, "/api/me")) }
        await tokens.held()
        await #expect(
            throws: refreshTokenRejected ? APIError.sessionExpired : APIError.http(status: 503, message: "Unavailable")
        ) {
            try await client.send(Endpoint<OK>(.get, "/api/other"))
        }
        tokens.release()

        if refreshTokenRejected {
            await #expect(throws: APIError.sessionExpired) { try await held.value }
            #expect(tokens.inner.current == nil)
            #expect(tokens.inner.expiredCount == 1)
        } else {
            #expect(try await held.value == OK(ok: true))
            #expect(tokens.inner.current?.accessToken == "access-2")
            #expect(tokens.inner.expiredCount == 0)
        }
    }

    @Test func cancellingRequestWaitingOnRefreshLeavesOthers() async throws {
        let refreshGate = StubGate()
        let server = tokenServer(refresh: .json(refreshedJSON, gate: refreshGate))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)
        let joins = Checkpoint()
        await client.observeRefreshJoins { joins.pass() }

        let starter = Task { try await client.send(Endpoint<OK>(.get, "/api/items/starter")) }
        await refreshGate.arrived()
        let waiter = Task { try await client.send(Endpoint<OK>(.get, "/api/items/waiter")) }
        await joins.reached()
        waiter.cancel()
        refreshGate.open()

        #expect(try await starter.value == OK(ok: true))
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(tokens.updates == [AuthTokens(accessToken: "access-2", refreshToken: "refresh-2")])
    }

    @Test func cancellingRequestThatStartedRefreshLeavesOthers() async throws {
        let refreshGate = StubGate()
        let server = tokenServer(refresh: .json(refreshedJSON, gate: refreshGate))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)
        let joins = Checkpoint()
        await client.observeRefreshJoins { joins.pass() }

        let starter = Task { try await client.send(Endpoint<OK>(.get, "/api/items/starter")) }
        await refreshGate.arrived()
        let waiter = Task { try await client.send(Endpoint<OK>(.get, "/api/items/waiter")) }
        await joins.reached()
        starter.cancel()
        refreshGate.open()

        await #expect(throws: CancellationError.self) { try await starter.value }
        #expect(try await waiter.value == OK(ok: true))
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(tokens.current == AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
        #expect(tokens.updates.count == 1)
    }

    @Test func concurrentRequestsExpireSessionOnce() async throws {
        let refreshGate = StubGate()
        let server = tokenServer(refresh: .text("Unauthorized", status: 401, gate: refreshGate))
        let tokens = InMemoryTokenProvider()
        let client = try makeClient(server, tokens: tokens)
        let joins = Checkpoint()
        await client.observeRefreshJoins { joins.pass() }

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
            await refreshGate.arrived()
            await joins.reached(4)
            refreshGate.open()
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
