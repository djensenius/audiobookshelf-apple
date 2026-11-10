import ABSAPI
import ABSCore
import ABSData
import CryptoKit
import Foundation
import Synchronization

@testable import ABSDownloads

/// How ``StubDownloadProtocol`` answers one request.
enum StubReply: Sendable {
    /// Responds after `delay` seconds.
    case status(Int, body: Data = Data("audio-bytes".utf8), delay: TimeInterval = 0)
    /// Fails after the headers with `NSURLErrorNetworkConnectionLost` and this resume data.
    case failure(resumeData: Data?)
}

/// A `URLProtocol` that answers requests for registered hosts and records them. Routes are
/// keyed by a unique host, so parallel tests never share state.
final class StubDownloadProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> StubReply

    private static let routes = Mutex<[String: (handler: Handler, requests: [URLRequest])]>([:])
    private let isStopped = Mutex(false)

    static func register(host: String, handler: @escaping Handler) {
        routes.withLock { $0[host] = (handler, []) }
    }

    static func requests(host: String) -> [URLRequest] {
        routes.withLock { $0[host]?.requests ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return routes.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return }
        let request = request
        guard
            let handler = Self.routes.withLock({ routes -> Handler? in
                routes[host]?.requests.append(request)
                return routes[host]?.handler
            })
        else { return }
        let reply = handler(request)
        if case .status(_, _, let delay) = reply, delay > 0 {
            let box = UncheckedProtocol(value: self)
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { box.value.deliver(reply, url: url) }
        } else {
            deliver(reply, url: url)
        }
    }

    override func stopLoading() {
        isStopped.withLock { $0 = true }
    }

    private func deliver(_ reply: StubReply, url: URL) {
        guard !isStopped.withLock({ $0 }) else { return }
        let status: Int
        switch reply {
        case .status(let code, _, _): status = code
        case .failure: status = 200
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        switch reply {
        case .status(_, let body, _):
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let resumeData):
            var info: [String: Any] = [:]
            info[NSURLSessionDownloadTaskResumeData] = resumeData
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: info))
        }
    }
}

// URLProtocol is not Sendable, but the URL loading system lets a protocol call its client
// from any thread, and the delayed delivery is the only use after `startLoading` returns.
private struct UncheckedProtocol: @unchecked Sendable {
    let value: StubDownloadProtocol
}

extension URLRequest {
    /// How many requests the stub has seen for this request's host, including this one.
    var stubCount: Int {
        StubDownloadProtocol.requests(host: url?.host() ?? "").count
    }
}

/// A ``DownloadSession`` over an ephemeral session with ``StubDownloadProtocol``. Resume data
/// can't be replayed by a stub, so a resumed task repeats the last fresh request, and the
/// resume data is recorded.
final class StubDownloadSession: DownloadSession {
    let session: URLSession
    private let state = Mutex<(lastRequest: URLRequest?, resumed: [Data])>((nil, []))

    init(delegate: any URLSessionDelegate) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubDownloadProtocol.self]
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    var resumedData: [Data] { state.withLock { $0.resumed } }

    /// Tasks left behind by a "previous launch", already running.
    let leftovers = Mutex<[URLSessionDownloadTask]>([])

    func leaveTask(_ request: URLRequest, description: String) {
        let task = session.downloadTask(with: request)
        task.taskDescription = description
        task.resume()
        leftovers.withLock { $0.append(task) }
    }

    func downloadTask(with request: URLRequest) -> URLSessionDownloadTask {
        state.withLock { $0.lastRequest = request }
        return session.downloadTask(with: request)
    }

    func downloadTask(withResumeData resumeData: Data) -> URLSessionDownloadTask {
        let request = state.withLock { state in
            state.resumed.append(resumeData)
            return state.lastRequest
        }
        return session.downloadTask(with: request!)
    }

    var allTasks: [URLSessionTask] {
        get async { await session.allTasks }
    }
}

/// Credentials whose token rotates on every forced refresh; records each request for them.
final class FakeCredentials: DownloadCredentialProviding {
    let configuration: APIClientConfiguration
    private let state = Mutex<(token: Int, calls: [String?])>((1, []))

    init(baseURL: URL) {
        configuration = try! APIClientConfiguration(baseURL: baseURL, customHeaders: ["X-Proxy": "proxy-secret"])
    }

    /// The `rejectedAccessToken` of each ``credentials(for:replacing:)`` call.
    var calls: [String?] { state.withLock { $0.calls } }

    /// Simulates a token refresh by another part of the app.
    func rotate() {
        state.withLock { $0.token += 1 }
    }

    func currentCredentials(for connectionID: UUID) async -> DownloadCredentials? {
        DownloadCredentials(configuration: configuration, accessToken: "token-\(state.withLock { $0.token })")
    }

    func credentials(for connectionID: UUID, replacing rejected: String?) async throws -> DownloadCredentials {
        let token = state.withLock { state in
            state.calls.append(rejected)
            if let rejected, rejected == "token-\(state.token)" { state.token += 1 }
            return state.token
        }
        return DownloadCredentials(configuration: configuration, accessToken: "token-\(token)")
    }
}

final class MemoryKeyStore: ResumeDataKeyStore {
    private let key = Mutex<SymmetricKey?>(nil)

    func loadKey() throws -> SymmetricKey? { key.withLock { $0 } }

    func createKey() throws -> SymmetricKey {
        key.withLock { stored in
            let created = stored ?? SymmetricKey(size: .bits256)
            stored = created
            return created
        }
    }
}

/// A clock whose sleeps return at once and are recorded.
final class RecordingClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let state = Mutex<(now: Duration, sleeps: [Duration])>((.zero, []))

    var now: Instant { Instant(offset: state.withLock { $0.now }) }
    var minimumResolution: Duration { .zero }
    var sleeps: [Duration] { state.withLock { $0.sleeps } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        state.withLock { state in
            state.sleeps.append(deadline.offset - state.now)
            state.now = deadline.offset
        }
        try Task.checkCancellation()
    }
}

/// An engine over an in-memory store, a stub server and a temporary directory.
final class DownloadHarness: Sendable {
    let host = "\(UUID().uuidString.lowercased()).stub.test"
    let root = FileManager.default.temporaryDirectory.appending(path: "downloads-\(UUID().uuidString)")
    let store: DownloadStore
    let connectionID: UUID
    let credentials: FakeCredentials
    let keyStore = MemoryKeyStore()
    let clock = RecordingClock()
    let sessions = Mutex<[StubDownloadSession]>([])

    init(handler: @escaping StubDownloadProtocol.Handler) async throws {
        let container = try DataStack(location: .inMemory).container
        let connection = try await ServerConnectionStore(modelContainer: container).upsertLogin(
            address: ServerAddress("https://\(host)/abs")!, userId: "usr_1", username: "reader",
            authMethod: .local, serverVersion: "2.26.0")
        connectionID = connection.id
        store = DownloadStore(modelContainer: container)
        credentials = FakeCredentials(baseURL: URL(string: "https://\(host)/abs")!)
        StubDownloadProtocol.register(host: host, handler: handler)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var locations: DownloadLocations { DownloadLocations(root: root) }
    var vault: ResumeDataVault { ResumeDataVault(directory: locations.resumeDataRoot, keyStore: keyStore) }
    var requests: [URLRequest] { StubDownloadProtocol.requests(host: host) }
    var session: StubDownloadSession? { sessions.withLock { $0.last } }

    /// - Parameter prepare: runs on the new session before the engine sees it, to leave tasks
    ///   behind as a previous launch would.
    func makeEngine(
        retryPolicy: RetryPolicy = .default, prepare: @escaping @Sendable (StubDownloadSession) -> Void = { _ in }
    ) -> DownloadEngine {
        DownloadEngine(
            store: store, credentials: credentials, vault: vault, locations: locations, retryPolicy: retryPolicy,
            networkAccess: { NetworkAccess(policy: .always) }, clock: clock, random: { 0.5 },
            makeSession: { [self] delegate in
                let session = StubDownloadSession(delegate: delegate)
                prepare(session)
                sessions.withLock { $0.append(session) }
                return session
            })
    }

    /// A record of `parts` audio files for `li_1`, saved to the store.
    @discardableResult
    func addRecord(
        parts: [UUID], state: DownloadState = .queued, partState: DownloadPartState = .queued
    ) async throws -> DownloadRecordDTO {
        let record = DownloadRecordDTO(
            key: MediaKey(serverConnectionID: connectionID, libraryItemId: "li_1"),
            mediaType: .book, title: "The Book", state: state, relativeDirectory: "li_1",
            media: LocalMediaSnapshot(metadata: .init(title: "The Book")),
            parts: parts.enumerated().map { index, id in
                DownloadPartDTO(
                    id: id, kind: .audio, serverPath: DownloadRequests.filePath(itemID: "li_1", ino: "\(index + 1)"),
                    filename: "\(index + 1).mp3", mimeType: "audio/mpeg", serverIno: "\(index + 1)",
                    trackIndex: index + 1,
                    expectedBytes: 11, destinationRelativePath: "li_1/\(index + 1).mp3", state: partState)
            })
        return try await store.upsertRecord(record).record
    }

    func fileURL(_ relativePath: String) -> URL {
        locations.downloadsRoot.appending(path: relativePath)
    }
}

extension DownloadEngine {
    /// The next update matching `predicate`; the suite's time limit bounds the wait.
    nonisolated func next(where predicate: (DownloadUpdate) -> Bool) async -> DownloadUpdate? {
        for await update in updates where predicate(update) {
            return update
        }
        return nil
    }

    nonisolated func nextRecordComplete() async -> DownloadUpdate? {
        await next {
            if case .recordComplete = $0 { true } else { false }
        }
    }

    nonisolated func nextPermanentFailure() async -> DownloadUpdate? {
        await next {
            if case .partFailed(_, _, _, false) = $0 { true } else { false }
        }
    }
}
