import ABSAPI
import ABSCore
import ABSData
import Foundation
import Synchronization

@testable import ABSDownloads

/// Holds stub replies back until the test opens it.
final class StubGate: Sendable {
    private let state = Mutex<(isOpen: Bool, pending: [@Sendable () -> Void])>((false, []))

    func open() {
        let pending = state.withLock { state in
            state.isOpen = true
            defer { state.pending = [] }
            return state.pending
        }
        for action in pending {
            action()
        }
    }

    func run(_ action: @escaping @Sendable () -> Void) {
        let runsNow = state.withLock { state in
            if !state.isOpen { state.pending.append(action) }
            return state.isOpen
        }
        if runsNow { action() }
    }
}

/// How ``StubDownloadProtocol`` answers one request.
enum StubReply: Sendable {
    /// Responds with `status` and `body`, from `from` (the request's URL by default), once
    /// `gate` (if any) opens.
    case status(
        Int, body: Data = Data("audio-bytes".utf8), contentType: String = "audio/mpeg", from: URL? = nil,
        gate: StubGate? = nil)
    /// Responds 200, sends `partialBody`, then fails with `code` and this resume data and
    /// background cancellation reason.
    case failure(
        code: Int = NSURLErrorNetworkConnectionLost, resumeData: Data? = nil, cancelReason: Int? = nil,
        partialBody: Data? = nil)
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
        if case .status(_, _, _, _, let gate?) = reply {
            let box = UncheckedProtocol(value: self)
            gate.run { box.value.deliver(reply, url: url) }
        } else {
            deliver(reply, url: url)
        }
    }

    override func stopLoading() {
        isStopped.withLock { $0 = true }
    }

    private func deliver(_ reply: StubReply, url: URL) {
        guard !isStopped.withLock({ $0 }), let client else { return }
        switch reply {
        case .status(let status, let body, let contentType, let from, _):
            let response = HTTPURLResponse(
                url: from ?? url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": contentType, "Content-Length": "\(body.count)"])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self)
        case .failure(let code, let resumeData, let cancelReason, let partialBody):
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "audio/mpeg"])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let partialBody { client.urlProtocol(self, didLoad: partialBody) }
            var info: [String: Any] = [:]
            info[NSURLSessionDownloadTaskResumeData] = resumeData
            info[NSURLErrorBackgroundTaskCancelledReasonKey] = cancelReason
            client.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: code, userInfo: info))
        }
    }
}

// URLProtocol is not Sendable, but the URL loading system lets a protocol call its client
// from any thread, and the gated delivery is the only use after `startLoading` returns.
private struct UncheckedProtocol: @unchecked Sendable {
    let value: StubDownloadProtocol
}

extension URLRequest {
    /// How many requests the stub has seen for this request's host, including this one.
    var stubCount: Int {
        StubDownloadProtocol.requests(host: url?.host() ?? "").count
    }

    var authorization: String? {
        value(forHTTPHeaderField: "Authorization")
    }
}

/// A ``DownloadSession`` over an ephemeral session with ``StubDownloadProtocol``. Resume data
/// can't be replayed by a stub, so a resumed task repeats the last fresh request, and the
/// resume data is recorded.
final class StubDownloadSession: DownloadSession {
    let session: URLSession
    private let delegate: DownloadSessionDelegate?
    private let state = Mutex<(lastRequest: URLRequest?, resumed: [Data])>((nil, []))

    init(delegate: any URLSessionDelegate) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubDownloadProtocol.self]
        self.delegate = delegate as? DownloadSessionDelegate
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

    /// What the system does once it has delivered a background wake's events.
    func finishBackgroundEvents() {
        delegate?.urlSessionDidFinishEvents(forBackgroundURLSession: session)
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

    func finishTasksAndInvalidate() {
        session.finishTasksAndInvalidate()
    }
}

/// Credentials whose token rotates on every forced refresh; records each request for them.
final class FakeCredentials: DownloadCredentialProviding {
    let configuration: APIClientConfiguration
    private let state = Mutex<(token: Int, calls: [String?])>((1, []))
    /// Runs before ``credentials(for:replacing:)`` returns.
    let hook = Mutex<(@Sendable () async -> Void)?>(nil)

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
        if let hook = hook.withLock({ $0 }) { await hook() }
        return DownloadCredentials(configuration: configuration, accessToken: "token-\(token)")
    }
}

struct TestError: Error {}

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

/// A clock whose sleeps announce themselves on ``started``, then last until cancelled.
final class SignallingClock: Clock {
    typealias Instant = ContinuousClock.Instant

    let started: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (started, continuation) = AsyncStream.makeStream()
    }

    var now: Instant { ContinuousClock.now }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        continuation.yield()
        try await Task.sleep(for: .seconds(3600))
    }
}

/// An engine over an in-memory store, a stub server and a temporary directory.
final class DownloadHarness: Sendable {
    let host = "\(UUID().uuidString.lowercased()).stub.test"
    let root = FileManager.default.temporaryDirectory.appending(path: "downloads-\(UUID().uuidString)")
    let store: DownloadStore
    let localItems: LocalItemStore
    let connectionID: UUID
    let credentials: FakeCredentials
    let keyStore = MemoryKeyStore()
    let clock = RecordingClock()
    let registry = DownloadEngineRegistry()
    let sessions = Mutex<[StubDownloadSession]>([])
    /// Each request the stub sees, in order.
    let requestStream: AsyncStream<URLRequest>

    init(handler: @escaping StubDownloadProtocol.Handler) async throws {
        let container = try DataStack(location: .inMemory).container
        let connection = try await ServerConnectionStore(modelContainer: container).upsertLogin(
            address: ServerAddress("https://\(host)/abs")!, userId: "usr_1", username: "reader",
            authMethod: .local, serverVersion: "2.26.0")
        connectionID = connection.id
        store = DownloadStore(modelContainer: container)
        localItems = LocalItemStore(modelContainer: container)
        credentials = FakeCredentials(baseURL: URL(string: "https://\(host)/abs")!)
        let (stream, continuation) = AsyncStream.makeStream(of: URLRequest.self)
        requestStream = stream
        StubDownloadProtocol.register(host: host) { request in
            continuation.yield(request)
            return handler(request)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var base: String { "https://\(host)/abs" }
    var locations: DownloadLocations { DownloadLocations(root: root) }
    var vault: ResumeDataVault { ResumeDataVault(directory: locations.resumeDataRoot, keyStore: keyStore) }
    var requests: [URLRequest] { StubDownloadProtocol.requests(host: host) }
    var session: StubDownloadSession? { sessions.withLock { $0.last } }

    /// Returns once the stub has seen `count` requests; the suite's time limit bounds the wait.
    func waitForRequests(_ count: Int) async {
        guard requests.count < count else { return }
        for await _ in requestStream where requests.count >= count {
            return
        }
    }

    /// - Parameter prepare: runs on the new session before the engine sees it, to leave tasks
    ///   behind as a previous launch would.
    func makeEngine(
        retryPolicy: RetryPolicy = .default,
        registry: DownloadEngineRegistry? = nil,
        readRecords: (@Sendable (DownloadStore) async throws -> [DownloadRecordDTO])? = nil,
        prepare: @escaping @Sendable (StubDownloadSession) -> Void = { _ in }
    ) -> DownloadEngine {
        DownloadEngine(
            store: store, localItems: localItems, credentials: credentials, vault: vault, locations: locations,
            retryPolicy: retryPolicy, networkAccess: { NetworkAccess(policy: .always) }, clock: clock,
            now: { .now }, random: { 0.5 }, makeSession: sessionFactory(prepare: prepare),
            registry: registry ?? self.registry, readRecords: readRecords ?? { try await $0.allRecords() })
    }

    func sessionFactory(
        prepare: @escaping @Sendable (StubDownloadSession) -> Void = { _ in }
    ) -> DownloadSessionFactory {
        { [self] delegate in
            let session = StubDownloadSession(delegate: delegate)
            prepare(session)
            sessions.withLock { $0.append(session) }
            return session
        }
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
                    trackIndex: index + 1, expectedBytes: 11, bytesWritten: partState == .completed ? 11 : 0,
                    destinationRelativePath: "li_1/\(index + 1).mp3", state: partState)
            })
        return try await store.upsertRecord(record).record
    }

    func fileURL(_ relativePath: String) -> URL {
        locations.downloadsRoot.appending(path: relativePath)
    }

    func fileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(relativePath).path(percentEncoded: false))
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

    nonisolated func nextFailure(willRetry: Bool) async -> DownloadUpdate? {
        await next {
            if case .partFailed(_, _, _, _, willRetry) = $0 { true } else { false }
        }
    }

    nonisolated func nextPermanentFailure() async -> DownloadUpdate? {
        await nextFailure(willRetry: false)
    }
}
