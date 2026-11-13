import ABSCore
import ABSDownloads
import Foundation
import Synchronization
import Testing

@testable import ABSAPI
@testable import ABSAppModel
@testable import ABSData

/// A server on a unique stub host that issues a new token pair on each sign-in and answers every
/// ebook fetch with 401.
private final class RejectingEbookServer: Sendable {
    static let ebookPath = "/abs/api/items/li_1/ebook"
    let host = "\(UUID().uuidString.lowercased()).ebook-credentials.test"
    private let issued = Mutex(0)

    init() {
        StubURLProtocol.register(host: host) { [self] request in respond(to: request) }
    }

    var address: String { "https://\(host)/abs" }

    var ebookFetches: [URLRequest] { StubURLProtocol.requests(host: host).filter { $0.url?.path() == Self.ebookPath } }

    private func respond(to request: URLRequest) -> StubResponse {
        issued.withLock { issued in
            switch request.url?.path() {
            case "/abs/status":
                return .json(
                    #"{"app":"audiobookshelf","serverVersion":"2.26.0","isInit":true,"authMethods":["local"]}"#)
            case "/abs/login", "/abs/auth/refresh":
                issued += 1
                return .json(
                    #"{"user":{"id":"usr-a","username":"david","type":"admin","token":null,"#
                        + #""accessToken":"access-\#(issued)","refreshToken":"refresh-\#(issued)"},"#
                        + #""userDefaultLibraryId":"lib1","serverSettings":{"version":"2.26.0"}}"#)
            case Self.ebookPath:
                return .json("{}", status: 401)
            default:
                return .json("{}", status: 404)
            }
        }
    }
}

/// The app's credentials, with a hook that runs before the credentials for a 401 retry are read.
private struct HookedCredentials: DownloadCredentialProviding {
    let base: AccountDownloadCredentials
    let beforeRetry: @Sendable () async throws -> Void

    func currentCredentials(for connectionID: UUID) async -> DownloadCredentials? {
        await base.currentCredentials(for: connectionID)
    }

    func credentials(for connectionID: UUID, replacing rejectedAccessToken: String?) async throws
        -> DownloadCredentials
    {
        if rejectedAccessToken != nil { try await beforeRetry() }
        return try await base.credentials(for: connectionID, replacing: rejectedAccessToken)
    }
}

/// Ebook fetches use the downloads' generation-checked credentials (#495).
@MainActor @Suite(.timeLimit(.minutes(1))) struct EbookFetchCredentialsTests {
    let manager: AccountManager

    init() throws {
        manager = AccountManager(
            store: ServerConnectionStore(modelContainer: try DataStack(location: .inMemory).container),
            keychain: InMemoryKeychain(),
            validator: ServerValidator(sessionConfiguration: { StubURLProtocol.sessionConfiguration() }),
            sessionConfiguration: { StubURLProtocol.sessionConfiguration() })
    }

    private func validated(_ server: RejectingEbookServer, customHeaders: [String: String] = [:]) async throws
        -> ValidatedServer
    {
        try await ServerValidator(sessionConfiguration: { StubURLProtocol.sessionConfiguration() })
            .validate(address: server.address, customHeaders: customHeaders)
    }

    /// The account signs in again with other custom headers before a 401 is retried: the new
    /// sign-in's token is never sent with the first sign-in's headers, and the fetch isn't retried.
    @Test func a401AfterSigningInAgainWithOtherHeadersIsNotRetried() async throws {
        let server = RejectingEbookServer()
        try await manager.connect(local: try await validated(server), username: "david", password: "pw")
        let id = try #require(manager.activeConnection?.id)
        let again = try await validated(server, customHeaders: ["X-Proxy": "1"])
        let manager = manager
        let credentials = HookedCredentials(
            base: AccountDownloadCredentials { try await manager.downloadAccess(for: $0, read: $1) },
            beforeRetry: { try await manager.connect(local: again, username: "david", password: "pw") })
        let fetcher = APIEbookFileFetcher(
            connectionID: id, credentials: credentials, sessionConfiguration: StubURLProtocol.sessionConfiguration())
        let directory = readerTemporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        await #expect(throws: APIError.unauthorized(message: nil)) {
            try await fetcher.downloadEbook(
                itemID: "li_1", fileIno: nil, to: directory.appending(path: "book"), maxBytes: 10)
        }

        #expect(manager.activeConnection?.id == id)
        let fetches = server.ebookFetches
        #expect(fetches.count == 1)
        #expect(fetches.first?.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        #expect(fetches.first?.value(forHTTPHeaderField: "X-Proxy") == nil)
        // Above all, no fetch pairs the new sign-in's token with the old headers.
        #expect(
            !fetches.contains {
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-2"
                    && $0.value(forHTTPHeaderField: "X-Proxy") == nil
            })
    }
}
