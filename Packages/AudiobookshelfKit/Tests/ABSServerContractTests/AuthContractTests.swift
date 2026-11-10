import ABSCore
import Foundation
import Testing

@testable import ABSAPI

@Suite("Server contract: discovery and sign-in", .requiresServer, .tags(.serverContract))
struct AuthContractTests {
    @Test("status, ping and validation identify a supported server")
    func discovery() async throws {
        let server = try ContractServer.require()
        let validated = try await ServerValidator().validate(address: server.address)
        #expect(validated.status.isInit)
        #expect(validated.status.app == "audiobookshelf")
        #expect(validated.status.supportsLocalLogin)
        #expect(validated.features.isSupported)
        if let version = server.version { #expect(validated.status.serverVersion == version) }

        let client = APIClient(configuration: validated.configuration, tokenProvider: InMemoryTokenProvider(nil))
        #expect(try await client.send(AuthEndpoints.ping()).success)
    }

    @Test("password login returns the root user, server settings and a JWT pair")
    func login() async throws {
        let server = try ContractServer.require()
        let session = try await server.signIn()
        let response = session.login.response
        #expect(response.user.username == server.username)
        #expect(response.user.type == .root)
        #expect(response.userDefaultLibraryId != nil)
        if let version = server.version { #expect(response.serverSettings?.version == version) }

        let tokens = session.login.tokens
        let access = try JWTClaims(tokens.accessToken)
        let refresh = try JWTClaims(tokens.refreshToken)
        #expect(access.type == "access")
        #expect(refresh.type == "refresh")
        #expect(access.userId == response.user.id)
        #expect(refresh.userId == response.user.id)
        // 2.26.0 issues 12 hour access and 7 day refresh tokens; 2.37.2 issues 1 hour and 30 day ones.
        #expect(access.lifetime >= 3600)
        #expect(refresh.lifetime >= 7 * 86400)
        #expect(access.lifetime < refresh.lifetime)

        let expiry = try #require(AccessTokenExpiry(token: tokens.accessToken))
        #expect(expiry.expiresAt == access.exp)
        #expect(expiry.issuedAt == access.iat)
    }

    @Test("a wrong password is invalid credentials")
    func wrongPassword() async throws {
        let server = try ContractServer.require()
        let validator = ServerValidator()
        let validated = try await validator.validate(address: server.address)
        await #expect(throws: ServerValidationError.invalidCredentials) {
            try await validator.login(to: validated, username: server.username, password: "not-the-password")
        }
    }

    @Test("/api/authorize returns the user and no new tokens")
    func authorize() async throws {
        let session = try await ContractServer.require().signIn()
        let result = try await ServerValidator().authorize(with: session.client)
        #expect(result.response.user.id == session.user.id)
        #expect(result.response.sessionTokens == nil)
        #expect(result.features.isSupported)
    }
}
