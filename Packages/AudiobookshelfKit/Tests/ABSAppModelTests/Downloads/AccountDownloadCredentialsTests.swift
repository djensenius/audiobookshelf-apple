import ABSAPI
import ABSDownloads
import Foundation
import Testing

@testable import ABSAppModel

/// Tokens a test controls; refreshes swap them like the Keychain provider.
private actor StoredTokens: TokenProvider {
    private var current: AuthTokens?

    init(_ tokens: AuthTokens?) {
        current = tokens
    }

    func tokens() async -> AuthTokens? { current }

    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool {
        guard current == expected else { return false }
        current = new
        return true
    }

    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool {
        guard current == rejected else { return false }
        current = nil
        return true
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AccountDownloadCredentialsTests {
    let host = "credentials-\(UUID().uuidString.lowercased()).example"
    let connectionID = UUID()
    let tokens = AuthTokens(accessToken: "access-1", refreshToken: "refresh-1")

    /// Credentials whose only connection is `connectionID`, with a client over `provider`.
    private func makeCredentials(_ provider: StoredTokens) throws -> (AccountDownloadCredentials, APIClient) {
        let configuration = try APIClientConfiguration(
            baseURL: try #require(URL(string: "https://\(host)/abs")), customHeaders: ["X-Proxy": "yes"])
        let client = APIClient(
            configuration: configuration, tokenProvider: provider,
            sessionConfiguration: StubURLProtocol.sessionConfiguration())
        let connectionID = connectionID
        let credentials = AccountDownloadCredentials { $0 == connectionID ? client : nil }
        return (credentials, client)
    }

    @Test func knownConnectionGivesItsConfigurationAndStoredToken() async throws {
        StubURLProtocol.register(host: host) { _ in .json("{}", status: 500) }
        let (credentials, _) = try makeCredentials(StoredTokens(tokens))

        let current = try #require(await credentials.currentCredentials(for: connectionID))
        #expect(current.accessToken == "access-1")
        #expect(current.configuration.baseURL.absoluteString == "https://\(host)/abs")
        #expect(current.configuration.customHeaders == ["X-Proxy": "yes"])

        // A token without a readable expiry isn't refreshed before a task.
        let fresh = try await credentials.credentials(for: connectionID, replacing: nil)
        #expect(fresh.accessToken == "access-1")
        // A rejected token that is no longer stored gives the stored one.
        let stale = try await credentials.credentials(for: connectionID, replacing: "access-0")
        #expect(stale.accessToken == "access-1")
        #expect(StubURLProtocol.requests(host: host).isEmpty)
    }

    @Test func rejectedStoredTokenIsRefreshedThroughTheClient() async throws {
        StubURLProtocol.register(host: host) { request in
            guard request.url?.path() == "/abs/auth/refresh",
                request.value(forHTTPHeaderField: "x-refresh-token") == "refresh-1"
            else { return .json("{}", status: 404) }
            return .json(#"{"user":{"accessToken":"access-2","refreshToken":"refresh-2"}}"#)
        }
        let provider = StoredTokens(tokens)
        let (credentials, client) = try makeCredentials(provider)

        let refreshed = try await credentials.credentials(for: connectionID, replacing: "access-1")

        #expect(refreshed.accessToken == "access-2")
        #expect(await client.currentAccessToken() == "access-2")
        #expect(await credentials.currentCredentials(for: connectionID)?.accessToken == "access-2")
        #expect(StubURLProtocol.requests(host: host).count == 1)
    }

    @Test func unknownConnectionHasNoCredentials() async throws {
        StubURLProtocol.register(host: host) { _ in .json("{}", status: 500) }
        let (credentials, _) = try makeCredentials(StoredTokens(tokens))
        let other = UUID()

        #expect(await credentials.currentCredentials(for: other) == nil)
        await #expect(throws: APIError.notAuthenticated) {
            try await credentials.credentials(for: other, replacing: nil)
        }
    }

    @Test func signedOutConnectionHasNoCredentials() async throws {
        StubURLProtocol.register(host: host) { _ in .json("{}", status: 500) }
        let (credentials, _) = try makeCredentials(StoredTokens(nil))

        #expect(await credentials.currentCredentials(for: connectionID) == nil)
        await #expect(throws: APIError.notAuthenticated) {
            try await credentials.credentials(for: connectionID, replacing: nil)
        }
        #expect(StubURLProtocol.requests(host: host).isEmpty)
    }
}
