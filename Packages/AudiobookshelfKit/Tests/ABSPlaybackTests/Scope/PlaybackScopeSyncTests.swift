import ABSCore
import ABSData
import Foundation
import Synchronization
import Testing

@testable import ABSAPI
@testable import ABSData
@testable import ABSPlayback

/// A scope over a ``SyncHarness``, with a local-session uploader over the harness's store and
/// ``uploads``, following `paths` when given.
@MainActor
private struct SyncScope {
    let s: SyncHarness
    let uploads: RecordingUploads
    let scope: PlaybackScope
    /// The paths the scope handled, and whether each asked for a server sync.
    private var handled: AsyncStream<(NetworkPath, Bool)>.Iterator

    init(paths: (any NetworkPathSource)? = nil) throws {
        s = try SyncHarness()
        let service = s.service
        // Each upload notes how many PATCHes had been sent by then.
        uploads = RecordingUploads(patchCount: { service.patches.count })
        let uploader = LocalSessionUploader(
            serverConnectionID: s.h.connectionID, store: s.store, service: uploads, deviceIdentifiers: SyncDevice(),
            sleep: { _ in })
        scope = PlaybackScope(
            coordinator: s.coordinator, syncer: s.syncer, services: nil, nowPlaying: RecordingNowPlaying(),
            uploader: uploader, paths: paths)
        // Set before the scope's path task first runs: nothing here suspends.
        let (stream, continuation) = AsyncStream.makeStream(of: (NetworkPath, Bool).self)
        scope.pathHandled = { continuation.yield(($0, $1)) }
        handled = stream.makeAsyncIterator()
    }

    /// Whether the next path the scope handled asked for a server sync.
    mutating func nextPath() async -> Bool? {
        var iterator = handled
        defer { handled = iterator }
        return await iterator.next(isolation: #isolation)?.1
    }

    /// Saves a pending local session for the harness's connection.
    @discardableResult
    func saveSession(active: Bool = false) async throws -> PendingLocalSessionDTO {
        let startedAt = s.h.clock.ago(3600)
        let session = PendingLocalSessionDTO(
            id: UUID().uuidString, key: s.h.key("offline"), userId: "user", mediaType: .book,
            displayTitle: "Title", duration: 3600, startTime: 0, startedAt: startedAt,
            updatedAt: startedAt.addingTimeInterval(30), timeListening: 30, currentTime: 30, isActive: active)
        try await s.store.saveSession(session)
        return session
    }
}

@MainActor
private func madeScope(networkPaths: (any NetworkPathSource)?) throws -> PlaybackScope {
    let writer = try LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
    var configuration = PlaybackScope.Configuration(
        connectionID: UUID(), client: nil, features: nil, deviceIdentifiers: SyncDevice(), writer: writer,
        settings: StubPlaybackSettings(), policy: StubStreamingPolicy(), engine: CoordinatorTestEngine(),
        tickInterval: 0.5, lastPlayed: { _ in InMemoryLastPlayedStore() }, queueStore: AdvanceQueueStore())
    configuration.networkPaths = networkPaths
    return PlaybackScope.make(configuration) { _ in RecordingNowPlaying() }
}

/// The scope's network sync (#184): server sync, flush, the library's progress, and replacing a
/// session the server no longer has.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PlaybackScopeSyncTests {
    // MARK: Make

    @Test func makeWiresTheSyncerToTheNetworkPathAndTheServicesToTheScope() throws {
        let scope = try madeScope(networkPaths: RecoveryPathSource())

        #expect(scope.syncer.pathTask != nil)
        #expect(scope.pathTask != nil)
        #expect(scope.services?.hasSessionGoneHandler == true)
        #expect(scope.uploader != nil)

        scope.retire(reason: .accountSwitch)
        #expect(scope.services?.hasSessionGoneHandler == false)
        #expect(scope.pathTask == nil)
    }

    /// The negative control: without a network path, neither the syncer nor the scope follows one.
    @Test func makeWithoutANetworkPathLeavesTheSyncerWithout() throws {
        let scope = try madeScope(networkPaths: nil)
        #expect(scope.syncer.pathTask == nil)
        #expect(scope.pathTask == nil)
    }

    // MARK: Server sync

    @Test(arguments: [false, true])
    func serverSyncDrainsProgressThenUploadsSessions(isFirstSync: Bool) async throws {
        let t = try SyncScope()
        try await t.s.store.recordEdit(ActiveRefreshFixture.edit(50), for: t.s.h.key("a"), now: t.s.h.clock.now)
        let closed = try await t.saveSession()
        let active = try await t.saveSession(active: true)

        t.scope.syncWithServer(isFirstSync: isFirstSync)
        await t.scope.waitForServerSync()

        #expect(t.s.service.patches == [.init(itemID: "a", update: SyncHarness.audio(50))])
        #expect(Set(t.uploads.batches.flatMap(\.self)) == [closed.id, active.id])
        // The drain had finished before the upload began.
        #expect(t.uploads.patchCounts == [1])
        #expect(try await t.s.store.session(id: closed.id) == nil)
        // Only the first sync after login deletes an acknowledged active session.
        let isActiveKept = try await t.s.store.session(id: active.id) != nil
        #expect(isActiveKept == !isFirstSync)
    }

    /// Retiring while the drain runs: the sync starts no upload after it.
    @Test func retirementStopsAServerSyncUnderWay() async throws {
        let t = try SyncScope()
        try await t.s.store.recordEdit(ActiveRefreshFixture.edit(50), for: t.s.h.key("a"), now: t.s.h.clock.now)
        try await t.saveSession()
        let patch = Gate()
        let patchStarted = Gate()
        t.s.service.state.withLock {
            $0.patchGates = [patch]
            $0.patchStarted = patchStarted
        }

        t.scope.syncWithServer(isFirstSync: true)
        await patchStarted.wait()
        t.scope.retire(reason: .accountSwitch)
        patch.open()
        await t.scope.waitForServerSync()

        #expect(t.uploads.batches.isEmpty)
        // Nor does a sync asked for after.
        t.scope.syncWithServer(isFirstSync: false)
        await t.scope.waitForServerSync()
        #expect(t.uploads.batches.isEmpty)
    }

    // MARK: Network path

    /// A reconnect the session doesn't see (the same account and client): the path coming back
    /// online retries the uploads the start's sync couldn't send.
    @Test func aPathReconnectRetriesTheUploadsAFailedSyncLeft() async throws {
        let paths = RecoveryPathSource()
        var t = try SyncScope(paths: paths)
        let session = try await t.saveSession()
        // The first path, online, asks for nothing.
        #expect(await t.nextPath() == false)
        t.uploads.isUnreachable = true
        t.scope.syncWithServer(isFirstSync: true)
        await t.scope.waitForServerSync()
        #expect(try await t.s.store.session(id: session.id) != nil)

        t.uploads.isUnreachable = false
        paths.isOnline = false
        #expect(await t.nextPath() == false)
        paths.isOnline = true
        #expect(await t.nextPath() == true)
        await t.scope.waitForServerSync()

        #expect(t.uploads.batches == [[session.id]])
        #expect(try await t.s.store.session(id: session.id) == nil)
    }

    /// A path that flaps while a sync runs queues one sync behind it, not one per reconnect.
    @Test func aFlappingPathQueuesOneServerSyncBehindTheRunningOne() async throws {
        let paths = RecoveryPathSource()
        var t = try SyncScope(paths: paths)
        // With nothing pending, each upload pass reads the store once.
        let passes = PassCount()
        let held = Gate()
        let started = Gate()
        await t.scope.uploader?.setAfterPendingRead {
            guard passes.increment() == 1 else { return }
            started.open()
            await held.wait()
        }
        #expect(await t.nextPath() == false)

        for _ in 0..<3 {
            paths.isOnline = false
            #expect(await t.nextPath() == false)
            paths.isOnline = true
            #expect(await t.nextPath() == true)
            // The first reconnect's sync is under way before the others arrive.
            await started.wait()
        }
        held.open()
        await t.scope.waitForServerSync()

        #expect(passes.value == 2)
    }

    /// Retiring stops following the path, so a later reconnect asks for nothing.
    @Test func aRetiredScopeStopsFollowingThePath() async throws {
        let paths = RecoveryPathSource()
        var t = try SyncScope(paths: paths)
        try await t.saveSession()
        #expect(await t.nextPath() == false)

        t.scope.retire(reason: .accountSwitch)
        #expect(t.scope.pathTask == nil)
        #expect(await eventually { paths.openStreams == 0 })
        paths.isOnline = false
        paths.isOnline = true
        await t.scope.waitForServerSync()
        #expect(t.uploads.batches.isEmpty)
    }

    // MARK: Flush

    @Test func flushReportsAndDrains() async throws {
        let t = try SyncScope()
        try await t.s.store.recordEdit(ActiveRefreshFixture.edit(50), for: t.s.h.key("b"), now: t.s.h.clock.now)
        await t.scope.play(itemID: "a", episodeID: nil, startTime: nil)
        await t.s.play(for: 7)
        let reports = t.s.service.reports.count

        await t.scope.flush()

        #expect(t.s.service.reports.count == reports + 1)
        #expect(t.s.service.patches.map(\.itemID).contains("b"))
    }

    /// The lifecycle bounds its flush: a cancelled flush returns while the report is still held,
    /// and the report carries on.
    @Test func aCancelledFlushReturnsWhileTheReportIsHeld() async throws {
        let t = try SyncScope()
        await t.scope.play(itemID: "a", episodeID: nil, startTime: nil)
        await t.s.play(for: 7)
        let reports = t.s.service.reports.count
        let held = Gate()
        t.s.service.state.withLock { $0.syncGates = [held] }
        let scope = t.scope

        let flush = Task { await scope.flush() }
        await t.s.service.waitForSyncs(reports + 1)
        flush.cancel()
        await flush.value

        held.open()
        await t.s.settle()
        #expect(t.s.service.reports.count == reports + 1)
    }

    // MARK: Library progress

    @Test func libraryProgressHearsPausesSeeksAndSpacedTicksUntilRetired() async throws {
        let t = try SyncScope()
        let heard = UpdateLog()
        t.scope.onProgress = { heard.updates.append($0) }
        await t.scope.play(itemID: "a", episodeID: nil, startTime: 50)
        await t.s.settle()
        heard.updates.removeAll()

        await t.s.play(for: 30)
        var updates = heard.updates
        #expect(!updates.isEmpty)
        #expect(updates.count <= 3)
        #expect(zip(updates, updates.dropFirst()).allSatisfy { $1.currentTime - $0.currentTime >= 10 })
        #expect(updates.allSatisfy { $0.key == t.s.h.key("a") && $0.duration == t.s.coordinator.duration })

        heard.updates.removeAll()
        t.s.coordinator.pause()
        await t.s.settle()
        #expect(heard.updates.map(\.currentTime) == [t.s.h.engine.currentTime])
        await t.s.coordinator.seek(to: 500)
        await t.s.settle()
        #expect(heard.updates.last?.currentTime == 500)

        // Retiring closes the session; the library hears nothing of it.
        updates = heard.updates
        t.scope.retire(reason: .accountSwitch)
        await t.s.settle()
        #expect(heard.updates == updates)
    }

    // MARK: Session gone

    @Test func aGoneSessionIsReplacedAtTheSamePosition() async throws {
        let t = try SyncScope()
        await t.scope.play(itemID: "a", episodeID: nil, startTime: 50)
        await t.s.settle()
        t.s.h.engine.currentTime = 100
        let gone = try #require(t.s.coordinator.session?.id)

        t.scope.sessionGone(gone)
        await t.scope.sessionReplacement?.value

        #expect(t.s.h.service.starts == ["a", "a"])
        #expect(t.s.h.engine.loads.last?.time == 100)
        let replacement = try #require(t.s.coordinator.session?.id)
        #expect(replacement != gone)
        #expect(t.s.coordinator.phase == .loaded)
    }

    /// The negative controls: a session that's no longer the loaded one, or any once retired, is
    /// left alone.
    @Test func aStaleOrRetiredSessionIsNotReplaced() async throws {
        let t = try SyncScope()
        await t.scope.play(itemID: "a", episodeID: nil, startTime: 50)
        await t.s.settle()
        let current = try #require(t.s.coordinator.session?.id)

        t.scope.sessionGone("\(current)-old")
        #expect(t.scope.sessionReplacement == nil)
        await t.s.coordinator.replaceGoneSession("\(current)-old")
        #expect(t.s.h.service.starts == ["a"])

        t.scope.retire(reason: .accountSwitch)
        t.scope.sessionGone(current)
        #expect(t.scope.sessionReplacement == nil)
        await t.s.coordinator.replaceGoneSession(current)
        #expect(t.s.h.service.starts == ["a"])
    }

    // MARK: History

    /// ``PlaybackScope/make(_:makeNowPlaying:)`` hands the configured history to the syncer: a play
    /// through the scope records its Play event (#158).
    @Test func aPlayThroughAMadeScopeRecordsItsPlayEvent() async throws {
        let history = HistorySpy()
        let connectionID = UUID()
        let writer = try LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
        var configuration = PlaybackScope.Configuration(
            connectionID: connectionID, client: try BookServerProtocol.client(),
            features: ServerFeatures(version: ServerVersion(2, 37, 2)), deviceIdentifiers: SyncDevice(),
            writer: writer, settings: StubPlaybackSettings(), policy: StubStreamingPolicy(),
            engine: CoordinatorTestEngine(), tickInterval: 0.5, lastPlayed: { _ in InMemoryLastPlayedStore() },
            queueStore: AdvanceQueueStore())
        configuration.history = history
        let scope = PlaybackScope.make(configuration) { _ in RecordingNowPlaying() }

        await scope.play(itemID: "B", episodeID: nil, startTime: 5)
        #expect(await eventually { scope.coordinator.isPlaying })
        await scope.syncer.waitForHistory()

        #expect(
            history.entries(.play).map(\.key) == [MediaKey(serverConnectionID: connectionID, libraryItemId: "B")])
        scope.retire(reason: .accountSwitch)
        _ = await scope.finishRetirement()
    }
}

/// Answers book `B`'s play with a session, and any other request with an empty 200, on the hosts
/// of its clients.
private final class BookServerProtocol: URLProtocol {
    static let hosts = Mutex<Set<String>>([])

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return hosts.withLock { $0.contains(host) }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
        else { return }
        let session = PlaybackSession(
            id: "sess-B", libraryItemId: "B", mediaType: .book, displayTitle: "Book", duration: 60,
            audioTracks: [
                AudioTrack(
                    index: 1, startOffset: 0, duration: 60, contentUrl: "/api/items/B/file/1", mimeType: "audio/mpeg")
            ])
        let isPlay = url.path().hasPrefix("/api/items/B/play")
        let body = isPlay ? (try? JSONEncoder().encode(session)) : nil
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// A client of a host of its own.
    static func client() throws -> APIClient {
        let host = "\(UUID().uuidString.lowercased()).book.test"
        hosts.withLock { _ = $0.insert(host) }
        let configuration = URLSessionConfiguration.absConnection()
        configuration.protocolClasses = [BookServerProtocol.self]
        return APIClient(
            configuration: try APIClientConfiguration(baseURL: try #require(URL(string: "https://\(host)"))),
            tokenProvider: BookTokens(), sessionConfiguration: configuration)
    }
}

private struct BookTokens: TokenProvider {
    func tokens() async -> ABSAPI.AuthTokens? { ABSAPI.AuthTokens(accessToken: "a", refreshToken: "r") }
    func replaceTokens(expected: ABSAPI.AuthTokens, with new: ABSAPI.AuthTokens) async -> Bool { false }
    func expireSession(ifCurrent rejected: ABSAPI.AuthTokens) async -> Bool { false }
}

private struct SyncDevice: DeviceIdentifying {
    func deviceIdentifier() async -> String { "device" }
}

/// What the scope's ``PlaybackScope/onProgress`` heard.
@MainActor
private final class UpdateLog {
    var updates: [PlaybackProgressUpdate] = []
}

/// Counts the uploader's passes.
private final class PassCount: Sendable {
    private let count = Mutex(0)

    var value: Int { count.withLock { $0 } }

    /// Counts one more pass, and returns the count.
    func increment() -> Int {
        count.withLock {
            $0 += 1
            return $0
        }
    }
}

/// Acknowledges every `local-all` upload, recording each batch's session IDs and how many PATCHes
/// had been sent when it arrived; while ``isUnreachable``, answers none (no connection).
private final class RecordingUploads: LocalSessionUploadService {
    private let state = Mutex<(batches: [[String]], patchCounts: [Int], isUnreachable: Bool)>(([], [], false))
    private let patchCount: @Sendable () -> Int

    init(patchCount: @escaping @Sendable () -> Int) {
        self.patchCount = patchCount
    }

    var batches: [[String]] { state.withLock { $0.batches } }
    var patchCounts: [Int] { state.withLock { $0.patchCounts } }
    var isUnreachable: Bool {
        get { state.withLock { $0.isUnreachable } }
        set { state.withLock { $0.isUnreachable = newValue } }
    }

    func uploadAll(_ batch: LocalPlaybackSessionBatch) async throws -> LocalSessionSyncResponse {
        let patches = patchCount()
        let isUnreachable = state.withLock { state in
            guard !state.isUnreachable else { return true }
            state.batches.append(batch.sessions.map(\.id))
            state.patchCounts.append(patches)
            return false
        }
        if isUnreachable { throw APIError.network(.notConnectedToInternet) }
        return LocalSessionSyncResponse(
            results: batch.sessions.map { .init(id: $0.id, success: true, progressSynced: true, error: nil) })
    }

    func upload(_ session: LocalPlaybackSessionPayload) async throws {}
}
