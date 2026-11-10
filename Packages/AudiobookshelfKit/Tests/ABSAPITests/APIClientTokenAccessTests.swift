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
