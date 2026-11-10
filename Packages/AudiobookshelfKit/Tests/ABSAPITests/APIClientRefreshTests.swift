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

    func update(_ tokens: AuthTokens) {}
    func sessionExpired() {}
}

private func makeClient(_ server: StubServer, tokens: any TokenProvider) -> APIClient {
    APIClient(
        configuration: APIClientConfiguration(baseURL: server.baseURL, customHeaders: ["X-Proxy": "1"]),
        tokenProvider: tokens,
        sessionConfiguration: server.sessionConfiguration()
    )
}

@Suite struct APIClientRefreshTests {
    @Test func refreshesOnUnauthorizedAndRetriesOnce() async throws {
        let server = tokenServer(refresh: .json(refreshedJSON))
        let tokens = InMemoryTokenProvider()
        let client = makeClient(server, tokens: tokens)

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
        #expect(await tokens.updates == [AuthTokens(accessToken: "access-2", refreshToken: "refresh-2")])
        #expect(await tokens.expiredCount == 0)
    }

    @Test func keepsRefreshTokenWhenResponseOmitsIt() async throws {
        let server = tokenServer(refresh: .json(#"{"user":{"accessToken":"access-2"}}"#))
        let tokens = InMemoryTokenProvider()
        let client = makeClient(server, tokens: tokens)

        _ = try await client.send(Endpoint<OK>(.get, "/api/me"))

        #expect(await tokens.current == AuthTokens(accessToken: "access-2", refreshToken: "refresh-1"))
    }

    @Test func concurrentUnauthorizedRequestsShareOneRefresh() async throws {
        let server = tokenServer(refresh: .json(refreshedJSON, delay: .milliseconds(200)))
        let tokens = InMemoryTokenProvider()
        let client = makeClient(server, tokens: tokens)

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
        #expect(await tokens.updates.count == 1)
    }

    @Test(arguments: [401, 403])
    func rejectedRefreshExpiresSession(status: Int) async {
        let server = tokenServer(refresh: .text("Invalid refresh token", status: status))
        let tokens = InMemoryTokenProvider()
        let client = makeClient(server, tokens: tokens)

        await #expect(throws: APIError.sessionExpired) {
            try await client.send(Endpoint<OK>(.get, "/api/me"))
        }
        #expect(await tokens.expiredCount == 1)
        #expect(await tokens.current == nil)
        #expect(server.requests(path: "/abs/api/me").count == 1)
    }

    @Test func concurrentRequestsExpireSessionOnce() async {
        let server = tokenServer(refresh: StubResponse(status: 401, delay: .milliseconds(200)))
        let tokens = InMemoryTokenProvider()
        let client = makeClient(server, tokens: tokens)

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
        #expect(await tokens.expiredCount == 1)
    }

    @Test func serverErrorDuringRefreshKeepsSession() async {
        let server = tokenServer(refresh: .text("Bad Gateway", status: 502))
        let tokens = InMemoryTokenProvider()
        let client = makeClient(server, tokens: tokens)

        await #expect(throws: APIError.http(status: 502, message: "Bad Gateway")) {
            try await client.send(Endpoint<OK>(.get, "/api/me"))
        }
        #expect(await tokens.expiredCount == 0)
        #expect(await tokens.current?.refreshToken == "refresh-1")
    }

    @Test func offlineDuringRefreshKeepsSession() async {
        let server = tokenServer(refresh: .failure(.notConnectedToInternet))
        let tokens = InMemoryTokenProvider()
        let client = makeClient(server, tokens: tokens)

        await #expect(throws: APIError.network(.notConnectedToInternet)) {
            try await client.send(Endpoint<OK>(.get, "/api/me"))
        }
        #expect(await tokens.expiredCount == 0)
    }

    @Test func unauthorizedAfterRefreshExpiresSession() async {
        let server = StubServer { request in
            request.url?.path() == refreshPath ? .json(refreshedJSON) : .text("Unauthorized", status: 401)
        }
        let tokens = InMemoryTokenProvider()
        let client = makeClient(server, tokens: tokens)

        await #expect(throws: APIError.sessionExpired) {
            try await client.send(Endpoint<OK>(.get, "/api/me"))
        }
        #expect(server.requests(path: refreshPath).count == 1)
        #expect(server.requests(path: "/abs/api/me").count == 2)
        #expect(await tokens.expiredCount == 1)
    }

    @Test func requestUsingStaleTokenRetriesWithoutRefreshing() async throws {
        let server = tokenServer(refresh: .json(refreshedJSON))
        let client = makeClient(server, tokens: RotatedTokenProvider())

        let result = try await client.send(Endpoint<OK>(.get, "/api/me"))

        #expect(result == OK(ok: true))
        #expect(server.requests(path: refreshPath).isEmpty)
        #expect(
            server.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
                "Bearer access-1", "Bearer access-2",
            ])
    }

    @Test func unauthenticatedEndpointNeverRefreshes() async {
        let server = tokenServer(refresh: .json(refreshedJSON))
        let tokens = InMemoryTokenProvider()
        let client = makeClient(server, tokens: tokens)

        await #expect(throws: APIError.unauthorized(message: "Unauthorized")) {
            try await client.send(Endpoint<EmptyResponse>(.post, "/login", requiresAuthentication: false))
        }
        #expect(server.requests(path: refreshPath).isEmpty)
        #expect(await tokens.expiredCount == 0)
    }

    @Test func malformedRefreshResponseIsDecodingError() async {
        let server = tokenServer(refresh: .json(#"{"user":{}}"#))
        let tokens = InMemoryTokenProvider()
        let client = makeClient(server, tokens: tokens)

        await #expect {
            try await client.send(Endpoint<OK>(.get, "/api/me"))
        } throws: { error in
            guard case .decoding = error as? APIError else { return false }
            return true
        }
        #expect(await tokens.expiredCount == 0)
    }
}
