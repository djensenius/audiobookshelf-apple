import ABSAPI
import ABSCore
import ABSData
import CryptoKit
import Foundation
import Synchronization

@testable import ABSDownloads

/// Credentials whose token rotates on every forced refresh; records each request for them.
final class FakeCredentials: DownloadCredentialProviding {
    let configuration: APIClientConfiguration
    private let state = Mutex<(token: Int, calls: [String?])>((1, []))
    private let failingCalls = Mutex<Set<Int>>([])
    /// Runs before ``credentials(for:replacing:)`` returns.
    let hook = Mutex<(@Sendable () async -> Void)?>(nil)

    init(baseURL: URL, customHeaders: [String: String] = [:]) {
        configuration = try! APIClientConfiguration(baseURL: baseURL, customHeaders: customHeaders)
    }

    /// The `rejectedAccessToken` of each ``credentials(for:replacing:)`` call.
    var calls: [String?] { state.withLock { $0.calls } }

    func failCredentials(onCall call: Int) {
        failingCalls.withLock { _ = $0.insert(call) }
    }

    /// Simulates a token refresh by another part of the app.
    func rotate() {
        state.withLock { $0.token += 1 }
    }

    func currentCredentials(for connectionID: UUID) async -> DownloadCredentials? {
        DownloadCredentials(configuration: configuration, accessToken: "token-\(state.withLock { $0.token })")
    }

    func credentials(for connectionID: UUID, replacing rejected: String?) async throws -> DownloadCredentials {
        let (token, call) = state.withLock { state in
            state.calls.append(rejected)
            if let rejected, rejected == "token-\(state.token)" { state.token += 1 }
            return (state.token, state.calls.count)
        }
        if let hook = hook.withLock({ $0 }) { await hook() }
        if failingCalls.withLock({ $0.remove(call) != nil }) { throw TestError() }
        return DownloadCredentials(configuration: configuration, accessToken: "token-\(token)")
    }
}

struct TestError: Error {}

/// A ``MemoryKeyStore`` whose next read can be made to fail, like a locked Keychain.
final class FlakyKeyStore: ResumeDataKeyStore {
    private let keys = MemoryKeyStore()
    private let failsNextLoad = Mutex(false)

    func failNextLoad() {
        failsNextLoad.withLock { $0 = true }
    }

    func loadKey() throws -> SymmetricKey? {
        if failsNextLoad.withLock({ fails in
            defer { fails = false }
            return fails
        }) {
            throw TestError()
        }
        return try keys.loadKey()
    }

    func createKey() throws -> SymmetricKey {
        try keys.createKey()
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

/// A clock whose sleeps announce themselves on ``started``, then last until cancelled.
final class SignallingClock: Clock {
    typealias Instant = ContinuousClock.Instant

    let started: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let sleepCount = Mutex(0)

    var sleeps: Int { sleepCount.withLock { $0 } }

    init() {
        (started, continuation) = AsyncStream.makeStream()
    }

    var now: Instant { ContinuousClock.now }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        sleepCount.withLock { $0 += 1 }
        continuation.yield()
        try await Task.sleep(for: .seconds(3600))
    }
}

/// A clock whose sleeps announce themselves on ``started`` and last until ``fire()`` or cancellation.
final class FiringClock: Clock {
    typealias Instant = ContinuousClock.Instant

    let started: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let sleepers = Mutex<[UUID: CheckedContinuation<Void, any Error>]>([:])

    init() {
        (started, continuation) = AsyncStream.makeStream()
    }

    var now: Instant { ContinuousClock.now }
    var minimumResolution: Duration { .zero }

    /// Ends every sleep that has started.
    func fire() {
        let waiting = sleepers.withLock { sleepers in
            defer { sleepers = [:] }
            return Array(sleepers.values)
        }
        for sleeper in waiting { sleeper.resume() }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (sleeper: CheckedContinuation<Void, any Error>) in
                let isCancelled = sleepers.withLock { sleepers in
                    if Task.isCancelled { return true }
                    sleepers[id] = sleeper
                    return false
                }
                if isCancelled {
                    sleeper.resume(throwing: CancellationError())
                } else {
                    continuation.yield()
                }
            }
        } onCancel: {
            sleepers.withLock { $0.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }
}

/// Holds chosen parts at the point of a permanent failure where the part's own failure is
/// saved but its siblings aren't stopped yet, and reports where each failure ends.
final class FailureSeams: Sendable {
    /// The parts that reached the hold, in order.
    let held: AsyncStream<UUID>
    /// The parts whose permanent failure has been handled completely, in order.
    let settled: AsyncStream<UUID>
    /// The parts a start found settling, in order.
    let foundSettling: AsyncStream<Set<UUID>>
    private let heldContinuation: AsyncStream<UUID>.Continuation
    private let settledContinuation: AsyncStream<UUID>.Continuation
    private let foundSettlingContinuation: AsyncStream<Set<UUID>>.Continuation
    private let holding = Mutex<Set<UUID>>([])
    private let gate = StubGate()

    init() {
        (held, heldContinuation) = AsyncStream.makeStream()
        (settled, settledContinuation) = AsyncStream.makeStream()
        (foundSettling, foundSettlingContinuation) = AsyncStream.makeStream()
    }

    /// Holds the next failure of each part, once.
    func hold(_ partIDs: UUID...) {
        holding.withLock { $0.formUnion(partIDs) }
    }

    func release() {
        gate.open()
    }

    func nextHeld() async -> UUID? { await held.first { _ in true } }
    func nextSettled() async -> UUID? { await settled.first { _ in true } }
    func nextFoundSettling() async -> Set<UUID>? { await foundSettling.first { _ in true } }

    var beforeStoppingSiblings: @Sendable (UUID) async -> Void {
        { [self] partID in
            guard holding.withLock({ $0.remove(partID) != nil }) else { return }
            heldContinuation.yield(partID)
            await withCheckedContinuation { continuation in gate.run { continuation.resume() } }
        }
    }

    var afterPermanentFailure: @Sendable (UUID) async -> Void {
        { [self] partID in settledContinuation.yield(partID) }
    }

    var startFoundSettling: @Sendable (Set<UUID>) async -> Void {
        { [self] partIDs in foundSettlingContinuation.yield(partIDs) }
    }
}

/// Counts each path's requests, so a handler can answer one path's first request differently.
final class PathCounter: Sendable {
    private let counts = Mutex<[String: Int]>([:])

    /// The request's number among those for its path, from 1.
    func next(_ request: URLRequest) -> Int {
        counts.withLock { counts in
            counts[request.url?.path() ?? "", default: 0] += 1
            return counts[request.url?.path() ?? "", default: 0]
        }
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
    let keyStore: any ResumeDataKeyStore
    let clock = RecordingClock()
    let registry = DownloadEngineRegistry()
    let sessions = Mutex<[StubDownloadSession]>([])
    /// Each request the stub sees, in order.
    let requestStream: AsyncStream<URLRequest>
    /// How many tasks have completed; ``completionStream`` yields after each.
    let completions = Mutex(0)
    /// Each completed task's `URLError` code, `nil` for a success (or another error), in order.
    let completionErrors = Mutex<[URLError.Code?]>([])
    let completionStream: AsyncStream<Void>
    private let completionContinuation: AsyncStream<Void>.Continuation

    init(
        keyStore: any ResumeDataKeyStore = MemoryKeyStore(), customHeaders: [String: String] = [:],
        handler: @escaping StubDownloadProtocol.Handler
    ) async throws {
        self.keyStore = keyStore
        (completionStream, completionContinuation) = AsyncStream.makeStream()
        let container = try DataStack(location: .inMemory).container
        let connection = try await ServerConnectionStore(modelContainer: container).upsertLogin(
            address: ServerAddress("https://\(host)/abs")!, userId: "usr_1", username: "reader",
            authMethod: .local, serverVersion: "2.26.0")
        connectionID = connection.id
        store = DownloadStore(modelContainer: container)
        localItems = LocalItemStore(modelContainer: container)
        credentials = FakeCredentials(baseURL: URL(string: "https://\(host)/abs")!, customHeaders: customHeaders)
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

    /// How many requests the stub has seen for the file with this `ino` (part N has ino N).
    func requestCount(file ino: Int) -> Int {
        requests.filter { $0.url?.path().contains("/file/\(ino)/") == true }.count
    }

    /// Returns once the stub has seen `count` requests; the suite's time limit bounds the wait.
    func waitForRequests(_ count: Int) async {
        guard requests.count < count else { return }
        for await _ in requestStream where requests.count >= count {
            return
        }
    }

    /// Returns once the stub has seen `count` requests for the file with this `ino`; the suite's
    /// time limit bounds the wait. A resumed task reaches the stub later, on the session's queue.
    func waitForRequests(file ino: Int, count: Int) async {
        guard requestCount(file: ino) < count else { return }
        for await _ in requestStream where requestCount(file: ino) >= count {
            return
        }
    }

    /// Returns once the delegate has handled `count` task completions; the suite's time limit
    /// bounds the wait. Follow with `processPendingEvents()` for the engine to handle them.
    func waitForCompletions(_ count: Int) async {
        guard completions.withLock({ $0 }) < count else { return }
        for await _ in completionStream where completions.withLock({ $0 }) >= count {
            return
        }
    }

    /// - Parameters:
    ///   - prepare: runs on the new session before the engine sees it, to leave tasks behind as
    ///     a previous launch would.
    ///   - listing: awaited before the session lists its tasks.
    func makeEngine(
        retryPolicy: RetryPolicy = .default,
        clock: (any Clock<Duration>)? = nil,
        registry: DownloadEngineRegistry? = nil,
        readRecords: (@Sendable (DownloadStore) async throws -> [DownloadRecordDTO])? = nil,
        readRecord: (@Sendable (DownloadStore, UUID) async throws -> DownloadRecordDTO?)? = nil,
        cancel: (@Sendable (URLSessionDownloadTask) async -> Data?)? = nil,
        beforeStoppingSiblings: (@Sendable (UUID) async -> Void)? = nil,
        afterPermanentFailure: (@Sendable (UUID) async -> Void)? = nil,
        beforeReplayStart: (@Sendable (UUID) async -> Void)? = nil,
        startFoundSettling: (@Sendable (Set<UUID>) async -> Void)? = nil,
        adoptionStarted: (@Sendable (UUID) async -> Void)? = nil,
        listing: (@Sendable () async -> Void)? = nil,
        beforeClearingResumeFlag: (@Sendable (UUID) async throws -> Void)? = nil,
        afterUpsertingLocalItem: (@Sendable (UUID) async -> Void)? = nil,
        preflight: any DownloadRedirectPreflighting = StubPreflight(),
        prepare: @escaping @Sendable (StubDownloadSession) -> Void = { _ in }
    ) -> DownloadEngine {
        let stubFactory = sessionFactory(prepare: prepare)
        var factory = stubFactory
        if let listing {
            factory = { ListingSession(base: stubFactory($0), listing: listing) }
        }
        return DownloadEngine(
            store: store, localItems: localItems, credentials: credentials, vault: vault, locations: locations,
            retryPolicy: retryPolicy, networkAccess: { NetworkAccess(policy: .always) }, clock: clock ?? self.clock,
            now: { .now }, random: { 0.5 }, makeSession: factory,
            registry: registry ?? self.registry, readRecords: readRecords ?? { try await $0.allRecords() },
            readRecord: readRecord ?? { try await $0.record(id: $1) },
            cancelKeepingResumeData: cancel ?? { await $0.cancelByProducingResumeData() },
            beforeStoppingSiblings: beforeStoppingSiblings, afterPermanentFailure: afterPermanentFailure,
            beforeReplayStart: beforeReplayStart, startFoundSettling: startFoundSettling,
            adoptionStarted: adoptionStarted, beforeClearingResumeFlag: beforeClearingResumeFlag,
            afterUpsertingLocalItem: afterUpsertingLocalItem, preflight: preflight)
    }

    func sessionFactory(
        prepare: @escaping @Sendable (StubDownloadSession) -> Void = { _ in }
    ) -> DownloadSessionFactory {
        { [self] delegate in
            let session = StubDownloadSession(delegate: delegate) { [weak self] error in
                self?.completionErrors.withLock { $0.append((error as? URLError)?.code) }
                self?.completions.withLock { $0 += 1 }
                self?.completionContinuation.yield()
            }
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

/// A session that awaits `listing` before it lists its tasks, as a relaunch's slow
/// `getAllTasks` would.
final class ListingSession: DownloadSession {
    let base: any DownloadSession
    let listing: @Sendable () async -> Void

    init(base: any DownloadSession, listing: @escaping @Sendable () async -> Void) {
        self.base = base
        self.listing = listing
    }

    func downloadTask(with request: URLRequest) -> URLSessionDownloadTask { base.downloadTask(with: request) }

    func downloadTask(withResumeData resumeData: Data) -> URLSessionDownloadTask {
        base.downloadTask(withResumeData: resumeData)
    }

    var allTasks: [URLSessionTask] {
        get async {
            await listing()
            return await base.allTasks
        }
    }

    func finishTasksAndInvalidate() { base.finishTasksAndInvalidate() }
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

/// A redirect check that records each request and answers with `answer` (the request itself by
/// default), without a network request. `answer` gets the request and its zero-based attempt.
/// A network wait answers `networkWait` (a network was waited for, by default).
final class StubPreflight: DownloadRedirectPreflighting {
    typealias Answer = @Sendable (URLRequest, Int) throws(DownloadRedirectPreflightError) -> URLRequest

    private let answer: Answer
    private let networkWait: @Sendable () async -> Bool
    private let checked = Mutex<[URLRequest]>([])
    private let waited = Mutex(0)

    init(
        answer: @escaping Answer = { request, _ in request },
        networkWait: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.answer = answer
        self.networkWait = networkWait
    }

    /// Each request checked, in order.
    var requests: [URLRequest] { checked.withLock { $0 } }
    /// How many network waits began.
    var networkWaits: Int { waited.withLock { $0 } }

    func waitForNetwork(_ request: URLRequest) async -> Bool {
        waited.withLock { $0 += 1 }
        return await networkWait()
    }

    func check(_ request: URLRequest) async throws(DownloadRedirectPreflightError) -> URLRequest {
        let attempt = checked.withLock { checked in
            defer { checked.append(request) }
            return checked.count
        }
        return try answer(request, attempt)
    }
}
