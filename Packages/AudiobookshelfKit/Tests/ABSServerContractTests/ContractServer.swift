import ABSAPI
import ABSCore
import Foundation
import Testing

/// The server the contract tests run against. `scripts/test-server.sh` starts one and sets the
/// environment; without `ABS_TEST_SERVER_URL` every suite is skipped.
struct ContractServer: Sendable {
    let address: String
    let username: String
    let password: String
    /// The release the script started, when it did.
    let version: String?

    static let current: ContractServer? = {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["ABS_TEST_SERVER_URL"], !address.isEmpty else { return nil }
        return ContractServer(
            address: address, username: environment["ABS_TEST_USERNAME"] ?? "root",
            password: environment["ABS_TEST_PASSWORD"] ?? "", version: environment["ABS_TEST_SERVER_VERSION"])
    }()

    static func require() throws -> ContractServer {
        try #require(current, "ABS_TEST_SERVER_URL is not set")
    }

    /// Whether the server still accepts a refresh token a refresh has replaced. Known for the two
    /// pinned releases (2.26.0 rejects it at once; 2.37.2 has a 10 minute grace period); `nil`
    /// for any other server, where only the invariants are checked.
    var acceptsReplacedRefreshToken: Bool? {
        switch version {
        case "2.26.0": false
        case "2.37.2": true
        default: nil
        }
    }
}

extension Tag {
    @Tag static var serverContract: Self
}

extension Trait where Self == ConditionTrait {
    /// Runs a suite only when a server is configured; otherwise it is reported as skipped.
    static var requiresServer: Self {
        .enabled(
            if: ContractServer.current != nil,
            "Set ABS_TEST_SERVER_URL to run the server contract tests (docs/testing/server-contracts.md)")
    }
}

/// A signed-in user: the production client, its token store and the login that created them.
struct ContractSession: Sendable {
    let client: APIClient
    let tokens: InMemoryTokenProvider
    let login: LoginResult
    let server: ValidatedServer

    var user: User { login.response.user }
    var configuration: APIClientConfiguration { server.configuration }

    /// Makes the stored access token one the server rejects. An expired token is rejected the
    /// same way (401 `Unauthorized`), so the client's recovery is the same.
    func invalidateAccessToken() {
        guard let current = tokens.current else { return }
        tokens.signIn(AuthTokens(accessToken: "not-a-valid-token", refreshToken: current.refreshToken))
    }
}

/// A playing device; every call is a new device, so sessions don't close each other.
func contractDevice(_ id: String = UUID().uuidString) -> DeviceInfo {
    DeviceInfo(
        deviceId: id, deviceName: "Contract tests", osName: "macOS", clientName: "Audiobookshelf Contract Tests",
        clientVersion: "0")
}

extension ContractSession {
    /// Starts a session as the app does: direct play for the formats `AVPlayer` handles.
    func play(
        _ itemID: String, episodeID: String? = nil, device: DeviceInfo = contractDevice()
    ) async throws -> PlaybackSession {
        let request = PlaybackStartRequest(deviceInfo: device, supportedMimeTypes: ["audio/mpeg", "audio/mp4"])
        return try await client.send(SessionEndpoints.start(itemID: itemID, episodeID: episodeID, request: request))
    }

    func report(_ time: Double, listened: Double, duration: Double = 50) throws -> PlaybackSyncReport {
        try #require(PlaybackSyncReport(currentTime: time, timeListened: listened, duration: duration))
    }

    func sync(_ playback: PlaybackSession, to time: Double, listened: Double) async throws {
        let body = try report(time, listened: listened, duration: playback.duration)
        _ = try await client.send(SessionEndpoints.sync(sessionID: playback.id, report: body))
    }

    /// `PATCH /api/me/progress/:itemID[/:episodeID]` with one of the production update bodies.
    func patch(_ itemID: String, episodeID: String? = nil, _ update: MediaProgressUpdate) async throws {
        _ = try await client.send(ProgressEndpoints.update(itemID: itemID, episodeID: episodeID, update))
    }

    /// The user's progress for the item, which the test expects to exist.
    func progress(_ itemID: String, episodeID: String? = nil) async throws -> MediaProgress {
        try #require(
            try await client.mediaProgress(itemID: itemID, episodeID: episodeID), "No progress for \(itemID)")
    }
}

/// Server tokens carry whole-second timestamps, and 2.26.0 adds no random id, so two tokens
/// issued for the same user in the same second are identical. Waits until the next one.
func waitForNextTokenSecond() async throws {
    try await Task.sleep(for: .milliseconds(1100))
}

/// Whether a time in seconds is within `tolerance` of `expected`. The servers differ on MP3
/// durations by up to 0.1 s: 2.26.0 counts the encoder's padding, 2.37.2 doesn't.
func approximately(_ value: Double?, _ expected: Double, tolerance: Double = 0.5) -> Bool {
    guard let value else { return false }
    return abs(value - expected) <= tolerance
}

/// Epoch milliseconds, the unit of the server's `lastUpdate`, `startedAt` and `finishedAt`.
func milliseconds(_ date: Date) -> Int {
    Int((date.timeIntervalSince1970 * 1000).rounded())
}

/// Expects `operation` to fail with the server's 401.
func expectUnauthorized<T>(
    sourceLocation: SourceLocation = #_sourceLocation, _ operation: () async throws -> T
) async {
    let error = await #expect(throws: APIError.self, sourceLocation: sourceLocation) { try await operation() }
    if case .unauthorized? = error { return }
    Issue.record("Expected a 401, got \(String(describing: error))", sourceLocation: sourceLocation)
}

/// Expects `operation` to fail with the server's 404.
func expectNotFound<T>(
    sourceLocation: SourceLocation = #_sourceLocation, _ operation: () async throws -> T
) async {
    let error = await #expect(throws: APIError.self, sourceLocation: sourceLocation) { try await operation() }
    if case .notFound? = error { return }
    Issue.record("Expected a 404, got \(String(describing: error))", sourceLocation: sourceLocation)
}

extension ContractServer {
    /// Signs in with the production `ServerValidator`, as the app's connect screen does.
    func signIn(username: String? = nil, password: String? = nil) async throws -> ContractSession {
        let validator = ServerValidator()
        let server = try await validator.validate(address: address)
        let login = try await validator.login(
            to: server, username: username ?? self.username, password: password ?? self.password)
        let tokens = InMemoryTokenProvider(login.tokens)
        return ContractSession(
            client: server.makeClient(tokenProvider: tokens), tokens: tokens, login: login, server: server)
    }

    /// Runs `body` as a new user with no progress, bookmarks or sessions, then deletes the user.
    /// Each test uses its own user so tests can run in parallel and in any order.
    func withUser<T: Sendable>(_ body: (ContractSession) async throws -> T) async throws -> T {
        let admin = try await ContractAdmin.shared.session()
        let name = "contract-" + UUID().uuidString.prefix(8).lowercased()
        let password = UUID().uuidString
        let created = try await admin.client.send(
            Endpoint<CreatedUser>(.post, "/api/users", body: NewUser(username: name, password: password)))
        let deleteUser = Endpoint<EmptyResponse>(.delete, "/api/users/\(created.user.id)")
        let value: T
        do {
            value = try await body(try await signIn(username: name, password: password))
        } catch {
            _ = try? await admin.client.send(deleteUser)
            throw error
        }
        _ = try await admin.client.send(deleteUser)
        return value
    }
}

private struct NewUser: Encodable, Sendable {
    let username: String
    let password: String
    let type = "user"
    let isActive = true
}

private struct CreatedUser: Decodable, Sendable {
    struct Created: Decodable, Sendable {
        let id: String
    }
    let user: Created
}

/// The root user's session, signed in once per process. It creates and deletes the per-test users.
actor ContractAdmin {
    static let shared = ContractAdmin()
    private let cache = ContractLoadCache<ContractSession>()

    func session() async throws -> ContractSession {
        try await cache.value {
            try await ContractServer.require().signIn()
        }
    }
}

/// The items `scripts/test-server.sh` seeds, found by title.
struct SeedData: Sendable {
    /// A book of two MP3 files (30 s and 20 s) with no embedded chapters.
    let taleID: String
    /// A single M4B of 40 s with three embedded chapters.
    let singleFileID: String
    let podcastID: String
    /// The podcast's only episode (20 s).
    let episodeID: String
    let bookLibraryID: String
    let podcastLibraryID: String
}

actor ContractSeed {
    static let shared = ContractSeed()
    private let cache = ContractLoadCache<SeedData>()

    func data() async throws -> SeedData {
        try await cache.value {
            let client = try await ContractAdmin.shared.session().client
            let libraries = try await client.send(LibraryEndpoints.libraries()).libraries
            let books = try #require(libraries.first { $0.mediaType == .book })
            let podcasts = try #require(libraries.first { $0.mediaType == .podcast })
            let bookItems = try await client.send(LibraryEndpoints.items(libraryID: books.id))
            let podcastItems = try await client.send(LibraryEndpoints.items(libraryID: podcasts.id))
            func bookID(titled title: String) throws -> String {
                try #require(bookItems.results.first { $0.book?.metadata.title == title }, "Seeded book \(title)").id
            }
            let podcast = try #require(podcastItems.results.first)
            let expanded = try await client.send(ItemEndpoints.item(id: podcast.id))
            let episode = try #require(expanded.podcast?.episodes?.first)
            return SeedData(
                taleID: try bookID(titled: "The Synthetic Tale"), singleFileID: try bookID(titled: "Single File Tale"),
                podcastID: podcast.id, episodeID: episode.id, bookLibraryID: books.id, podcastLibraryID: podcasts.id)
        }
    }
}

/// Shares one asynchronous load among actor callers and caches only a successful result.
actor ContractLoadCache<Value: Sendable> {
    private var cached: Value?
    private struct Flight {
        let id: UUID
        var waiters: [UUID: CheckedContinuation<Value, any Error>]
    }
    private var inFlight: Flight?

    var waiterCount: Int { inFlight?.waiters.count ?? 0 }

    func value(loading load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if let cached { return cached }

        let loadID: UUID
        if let inFlight {
            loadID = inFlight.id
        } else {
            loadID = UUID()
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let cached {
                    continuation.resume(returning: cached)
                } else if var flight = inFlight {
                    flight.waiters[waiterID] = continuation
                    inFlight = flight
                } else {
                    inFlight = Flight(id: loadID, waiters: [waiterID: continuation])
                    Task { [weak self] in
                        let result: Result<Value, any Error>
                        do {
                            result = .success(try await load())
                        } catch {
                            result = .failure(error)
                        }
                        await self?.finish(loadID, with: result)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID, for: loadID) }
        }
    }

    private func cancel(_ waiterID: UUID, for loadID: UUID) {
        guard var flight = inFlight, flight.id == loadID,
            let continuation = flight.waiters.removeValue(forKey: waiterID)
        else { return }
        inFlight = flight
        continuation.resume(throwing: CancellationError())
    }

    private func finish(_ loadID: UUID, with result: Result<Value, any Error>) {
        guard let flight = inFlight, flight.id == loadID else { return }
        inFlight = nil

        switch result {
        case .success(let value):
            cached = value
            for continuation in flight.waiters.values {
                continuation.resume(returning: value)
            }
        case .failure(let error):
            for continuation in flight.waiters.values {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// The claims of an Audiobookshelf access or refresh token. The tests read them to check
/// lifetimes and rotation; the server alone decides whether a token is valid.
struct JWTClaims: Decodable, Sendable {
    let userId: String
    let type: String
    let iat: Double
    let exp: Double
    /// A unique token id: 2.37.2 adds one, 2.26.0 doesn't, so two tokens issued in the same second
    /// for the same user are identical there.
    let jti: String?

    var lifetime: Double { exp - iat }

    init(_ token: String) throws {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { throw CocoaError(.coderInvalidValue) }
        var base64 = segments[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        guard let payload = Data(base64Encoded: base64) else { throw CocoaError(.coderInvalidValue) }
        self = try JSONDecoder().decode(JWTClaims.self, from: payload)
    }
}
