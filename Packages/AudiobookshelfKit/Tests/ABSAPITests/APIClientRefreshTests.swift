import Foundation
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
