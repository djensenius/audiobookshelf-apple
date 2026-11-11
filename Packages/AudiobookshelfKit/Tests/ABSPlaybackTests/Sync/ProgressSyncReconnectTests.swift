import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// Coming back online drains pending progress and retries the active baseline (#171, L8).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProgressSyncReconnectTests {
    @MainActor
    private struct Fixture {
        let paths = StubNetworkPathSource()
        let s: SyncHarness
        var handled: AsyncStream<Bool>.Iterator

        init() throws {
            s = try SyncHarness(paths: paths)
            let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
            s.syncer.pathHandled = { _, drained in continuation.yield(drained) }
            handled = stream.makeAsyncIterator()
        }

        /// Sends `path` and returns whether handling it drained.
        mutating func send(_ path: NetworkPath) async -> Bool? {
            paths.send(path)
            var iterator = handled
            defer { handled = iterator }
            return await iterator.next(isolation: #isolation)
        }
    }

    @Test func reconnectDrainsPendingProgressOnce() async throws {
        var f = try Fixture()
        try await f.s.store.recordEdit(ActiveRefreshFixture.edit(50), for: f.s.h.key("a"), now: f.s.h.clock.now)

        #expect(await f.send(.wifi) == false)
        #expect(await f.send(.offline) == false)
        #expect(f.s.service.log.isEmpty)
        #expect(await f.send(.cellular) == true)
        #expect(f.s.service.patches == [.init(itemID: "a", update: SyncHarness.audio(50))])
        let log = f.s.service.log
        #expect(log.first == "get a")
        #expect(await f.send(.wifi) == false)
        #expect(f.s.service.log == log)
        #expect(try await f.s.store.progress(for: f.s.h.key("a"))?.needsServerSync == false)
    }

    /// A baseline lookup that failed while offline is retried when the network comes back.
    @Test func reconnectRetriesTheActiveBaseline() async throws {
        var f = try Fixture()
        let s = f.s
        await ActiveRefreshFixture.loadPaused(s)
        s.service.state.withLock {
            $0.fetchErrors = [.network(.notConnectedToInternet)]
            $0.serverProgress[s.h.key("a")] = ActiveRefreshFixture.reply(s)
        }
        #expect(await f.send(.offline) == false)
        await s.syncer.drainPendingProgress()
        #expect(s.service.state.withLock { $0.fetches } == [s.h.key("a")])
        #expect(try await s.store.progress(for: s.h.key("a"))?.serverBaseline == nil)

        #expect(await f.send(.wifi) == true)

        #expect(s.service.state.withLock { $0.fetches } == [s.h.key("a"), s.h.key("a")])
        #expect(try await s.store.progress(for: s.h.key("a"))?.serverBaseline?.currentTime == 900)
        ActiveRefreshFixture.expectNoWrites(s)
    }

    @Test func detachStopsFollowingThePath() async throws {
        var f = try Fixture()
        try await f.s.store.recordEdit(ActiveRefreshFixture.edit(50), for: f.s.h.key("a"), now: f.s.h.clock.now)
        #expect(await f.send(.offline) == false)
        let task = try #require(f.s.syncer.pathTask)

        f.s.syncer.detach()
        f.paths.send(.wifi)
        await task.value

        #expect(f.s.service.log.isEmpty)
        #expect(try await f.s.store.progress(for: f.s.h.key("a"))?.needsServerSync == true)
    }

    @Test func quiesceStopsFollowingThePath() async throws {
        var f = try Fixture()
        #expect(await f.send(.offline) == false)
        let task = try #require(f.s.syncer.pathTask)

        f.s.syncer.quiesceTransport()

        #expect(f.s.syncer.pathTask == nil)
        try #require(task.isCancelled)
        await task.value
        #expect(f.paths.isTerminated)
    }

    @Test func releasingTheSyncerStopsFollowingThePath() async throws {
        let paths = StubNetworkPathSource()
        let s = try SyncHarness()
        var syncer: ProgressSyncer? = ProgressSyncer(
            source: s.coordinator, service: s.service, store: s.store, paths: paths)
        let task = try #require(syncer?.pathTask)

        syncer = nil

        #expect(syncer == nil)
        try #require(task.isCancelled)
        await task.value
        #expect(paths.isTerminated)
    }
}
