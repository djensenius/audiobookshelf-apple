import ABSCore
import Foundation
import Testing

@testable import ABSAPI

/// The `POST /auth/refresh` body.
private struct RefreshReply: Decodable, Sendable {
    struct Tokens: Decodable, Sendable {
        let accessToken: String
        let refreshToken: String?
    }
    let user: Tokens
}

extension ContractSession {
    /// `POST /auth/refresh` as another device would send it: the token in the header, no cookies.
    fileprivate func refresh(with refreshToken: String) async throws -> RefreshReply {
        try await client.send(
            Endpoint<RefreshReply>(
                .post, "/auth/refresh", headers: ["x-refresh-token": refreshToken], requiresAuthentication: false,
                sendsCookies: false))
    }

    fileprivate func me() async throws -> User {
        try await client.send(Endpoint<User>(.get, "/api/me"))
    }
}

@Suite("Server contract: token refresh and rotation", .requiresServer, .tags(.serverContract))
struct TokenRefreshContractTests {
    // Every test uses its own user. 2.26.0 signs tokens without a random id, so two sign-ins of
    // one user within a second get the same refresh token, and revoking or rotating one ends
    // both sessions.

    @Test("a rejected access token is refreshed once and the request retried")
    func reactiveRefresh() async throws {
        try await ContractServer.require().withUser { session in
            let original = session.login.tokens
            try await waitForNextTokenSecond()
            session.invalidateAccessToken()

            #expect(try await session.me().id == session.user.id)

            #expect(session.tokens.updates.count == 1)
            let rotated = try #require(session.tokens.updates.first)
            #expect(rotated.accessToken != original.accessToken)
            #expect(rotated.refreshToken != original.refreshToken)
            #expect(try JWTClaims(rotated.accessToken).type == "access")
            #expect(try JWTClaims(rotated.refreshToken).type == "refresh")

            // The client kept what the server returned, so the next request needs no refresh.
            _ = try await session.me()
            #expect(session.tokens.updates.count == 1)
        }
    }

    @Test("the old refresh token follows the version's rotation rule")
    func rotation() async throws {
        let server = try ContractServer.require()
        try await server.withUser { session in
            let first = session.login.tokens
            try await waitForNextTokenSecond()

            let second = try await session.refresh(with: first.refreshToken)
            let rotated = try #require(second.user.refreshToken)
            #expect(rotated != first.refreshToken)
            #expect(second.user.accessToken != first.accessToken)

            // An access token a refresh replaced keeps working until it expires.
            let stale = APIClient(configuration: session.configuration, tokenProvider: InMemoryTokenProvider(first))
            #expect(try await stale.send(Endpoint<User>(.get, "/api/me")).id == session.user.id)

            switch server.acceptsReplacedRefreshToken {
            case false?:
                await expectUnauthorized { try await session.refresh(with: first.refreshToken) }
            case true?:
                // 2.37.2's grace period answers with the pair that replaced it, never a divergent one.
                let again = try await session.refresh(with: first.refreshToken)
                #expect(again.user.refreshToken == rotated)
            case nil:
                break
            }
            #expect(try await session.refresh(with: rotated).user.refreshToken != nil)
        }
    }

    @Test("concurrent requests with a rejected token share one refresh")
    func singleFlight() async throws {
        try await ContractServer.require().withUser { session in
            try await waitForNextTokenSecond()
            session.invalidateAccessToken()

            try await withThrowingTaskGroup(of: String.self) { group in
                for _ in 0..<8 { group.addTask { try await session.me().id } }
                for try await id in group { #expect(id == session.user.id) }
            }
            #expect(session.tokens.updates.count == 1)
            #expect(session.tokens.expiredCount == 0)
        }
    }

    @Test("a token about to expire is refreshed before the request; one far from expiry is not")
    func earlyRefresh() async throws {
        try await ContractServer.require().withUser { session in
            let original = session.login.tokens
            let expiry = try JWTClaims(original.accessToken).exp

            #expect(try await session.client.accessToken(replacing: nil) == original.accessToken)
            #expect(session.tokens.updates.isEmpty)

            try await waitForNextTokenSecond()
            await session.client.setNow { Date(timeIntervalSince1970: expiry - 60) }
            let refreshed = try await session.client.accessToken(replacing: nil)
            #expect(refreshed != original.accessToken)
            #expect(session.tokens.updates.count == 1)
            #expect(try await session.me().id == session.user.id)

            // The new token is a whole lifetime from the (faked) time it arrived.
            #expect(try await session.client.accessToken(replacing: nil) == refreshed)
            #expect(session.tokens.updates.count == 1)
        }
    }

    @Test("logout revokes the refresh token, and the client then reports the session ended")
    func logout() async throws {
        try await ContractServer.require().withUser { session in
            let tokens = session.login.tokens

            let reply = try await session.client.send(AuthEndpoints.logout(refreshToken: tokens.refreshToken))
            #expect(reply.redirectURL == nil)
            await expectUnauthorized { try await session.refresh(with: tokens.refreshToken) }

            session.invalidateAccessToken()
            await #expect(throws: APIError.sessionExpired) { try await session.me() }
            #expect(session.tokens.expiredCount == 1)
            #expect(session.tokens.current == nil)
        }
    }

    @Test("logout revokes the header's refresh token even when the cookie jar holds another")
    func logoutIgnoresJarCookie() async throws {
        let server = try ContractServer.require()
        try await server.withUser { other in
            try await server.withUser { session in
                // A refresh makes the server set a `refresh_token` cookie in this client's jar.
                session.invalidateAccessToken()
                _ = try await session.me()
                let current = try #require(session.tokens.current)
                let jar = try #require(session.client.cookieStorage)
                let cookie = try #require(
                    jar.cookies(for: session.configuration.baseURL)?.first { $0.name == "refresh_token" })
                #expect(cookie.value == current.refreshToken)

                // The server prefers that cookie to the header, so a plain logout would revoke
                // this session instead of the one named.
                let named = other.login.tokens.refreshToken
                _ = try await session.client.send(AuthEndpoints.logout(refreshToken: named))
                await expectUnauthorized { try await other.refresh(with: named) }
                #expect(try await session.refresh(with: current.refreshToken).user.accessToken.isEmpty == false)
            }
        }
    }
}
