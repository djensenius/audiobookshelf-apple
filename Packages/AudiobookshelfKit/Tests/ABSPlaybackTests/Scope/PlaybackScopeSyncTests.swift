import ABSCore
import ABSData
import Foundation
import Synchronization
import Testing

@testable import ABSAPI
@testable import ABSData
@testable import ABSPlayback

/// A scope over a ``SyncHarness``, with a local-session uploader over the harness's store and
/// ``uploads``.
@MainActor
private struct SyncScope {
    let s: SyncHarness
    let uploads: RecordingUploads
    let scope: PlaybackScope

    init() throws {
        s = try SyncHarness()
        let service = s.service
        // Each upload notes how many PATCHes had been sent by then.
        uploads = RecordingUploads(patchCount: { service.patches.count })
        let uploader = LocalSessionUploader(
            serverConnectionID: s.h.connectionID, store: s.store, service: uploads, deviceIdentifiers: SyncDevice(),
            sleep: { _ in })
        scope = PlaybackScope(
            coordinator: s.coordinator, syncer: s.syncer, services: nil, nowPlaying: RecordingNowPlaying(),
            uploader: uploader)
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
        let scope = try madeScope(networkPaths: StubNetworkPathSource())

        #expect(scope.syncer.pathTask != nil)
        #expect(scope.services?.hasSessionGoneHandler == true)
        #expect(scope.uploader != nil)

        scope.retire(reason: .accountSwitch)
        #expect(scope.services?.hasSessionGoneHandler == false)
    }

    /// The negative control: without a network path, the syncer has nothing to follow.
    @Test func makeWithoutANetworkPathLeavesTheSyncerWithout() throws {
        #expect(try madeScope(networkPaths: nil).syncer.pathTask == nil)
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
}

private struct SyncDevice: DeviceIdentifying {
    func deviceIdentifier() async -> String { "device" }
}

/// What the scope's ``PlaybackScope/onProgress`` heard.
@MainActor
private final class UpdateLog {
    var updates: [PlaybackProgressUpdate] = []
}

/// Acknowledges every `local-all` upload, recording each batch's session IDs and how many PATCHes
/// had been sent when it arrived.
private final class RecordingUploads: LocalSessionUploadService {
    private let state = Mutex<(batches: [[String]], patchCounts: [Int])>(([], []))
    private let patchCount: @Sendable () -> Int

    init(patchCount: @escaping @Sendable () -> Int) {
        self.patchCount = patchCount
    }

    var batches: [[String]] { state.withLock { $0.batches } }
    var patchCounts: [Int] { state.withLock { $0.patchCounts } }

    func uploadAll(_ batch: LocalPlaybackSessionBatch) async throws -> LocalSessionSyncResponse {
        let patches = patchCount()
        state.withLock {
            $0.batches.append(batch.sessions.map(\.id))
            $0.patchCounts.append(patches)
        }
        return LocalSessionSyncResponse(
            results: batch.sessions.map { .init(id: $0.id, success: true, progressSynced: true, error: nil) })
    }

    func upload(_ session: LocalPlaybackSessionPayload) async throws {}
}
