import ABSAPI
import Foundation
import Testing

@testable import ABSAppModel

/// One connection's tokens, shared by its clients like the Keychain provider.
private actor ConnectionTokens: TokenProvider {
    private var current: AuthTokens?

    init(_ tokens: AuthTokens) {
        current = tokens
    }

    func signIn(_ tokens: AuthTokens) { current = tokens }

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

extension BookmarkStoreTests {
    @Test func teardownCancelsLoadSoItIsNotRetriedWithNextSessionsTokens() async throws {
        let host = "bookmarks-\(UUID().uuidString.lowercased()).example"
        StubURLProtocol.register(host: host) { request in
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer access-2" else {
                return .json("{}", status: 401)
            }
            return .json(#"{"bookmarks":[{"libraryItemId":"item","title":"Stale","time":30}]}"#)
        }
        let tokens = ConnectionTokens(AuthTokens(accessToken: "access-1", refreshToken: "refresh-1"))
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: try #require(URL(string: "https://\(host)"))),
            tokenProvider: tokens, sessionConfiguration: StubURLProtocol.sessionConfiguration())
        let store = BookmarkStore()
        await store.sessionDidStart(bookmarkContext(client: client))

        let gate = StubURLProtocol.hold(host: host, path: "/api/me")
        let load = Task { try await store.refresh() }
        await gate.arrived()
        await store.sessionWillEnd(.signOut)
        // Signing back in to the same connection shares its credentials with the old request.
        await tokens.signIn(AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
        await store.sessionDidStart(bookmarkContext(client: client))
        gate.open()

        await #expect(throws: CancellationError.self) { try await load.value }
        #expect(await eventually { StubURLProtocol.abandonedRequests(host: host).count == 1 })
        let sent = StubURLProtocol.requests(host: host)
        #expect(sent.count == 1)
        #expect(!sent.contains { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-2" })
        #expect(store.bookmarks(itemID: "item").isEmpty)
        #expect(!store.hasLoaded)
        #expect(!store.isLoading)
    }
}
