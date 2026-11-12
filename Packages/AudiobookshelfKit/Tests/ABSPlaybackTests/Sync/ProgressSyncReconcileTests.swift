import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// An ambiguous `/sync` keeps its listening time until `GET /api/session/:id` shows whether the
/// server applied it (#381).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProgressSyncReconcileTests {
    /// A harness whose session and progress services share one session model.
    private static func modelHarness() throws -> (SyncHarness, ReconciliationSessionModel, SessionModelClient) {
        let s = try SyncHarness()
        let model = ReconciliationSessionModel(clock: s.h.clock)
        let client = SessionModelClient(model: model)
        s.h.service.state.withLock { $0.sessionClient = client }
        s.service.state.withLock { $0.sessionClient = client }
        return (s, model, client)
    }

    private static func serverTotal(
        _ model: ReconciliationSessionModel, _ client: SessionModelClient, _ s: SyncHarness
    ) async throws -> Double {
        let id = try #require(s.service.state.withLock { $0.syncs.first?.id })
        return try await model.lookup(client, id: id).timeListening
    }

    private static func lookups(_ s: SyncHarness) -> Int {
        s.service.log.filter { $0.hasPrefix("lookup") }.count
    }

    /// The client gives up on a `/sync` the server completes later: the lookup shows it applied,
    /// so its time isn't sent again.
    @Test func lateCompletingSyncIsCountedOnce() async throws {
        let (s, model, client) = try Self.modelHarness()
        let late = ReconciliationSessionModel.Request()
        defer { late.release() }
        late.enter.open()
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15)
        await model.enqueue(late, for: .sync)
        s.service.state.withLock { $0.abandonedSyncs = [late] }

        // t = 30: the report times out while the server still holds it, then applies it.
        await s.play(for: 15)
        #expect(s.service.log.contains("sync 2 timed out"))
        late.release()
        await late.completed.wait()
        #expect(try await Self.serverTotal(model, client, s) == 30)

        // t = 45: the lookup finds it applied, so only the new 15 s go out.
        await s.play(for: 15)
        #expect(Self.lookups(s) == 1)
        #expect(s.service.reports.map(\.timeListened) == [15, 15, 15])
        #expect(try await Self.serverTotal(model, client, s) == 45)
    }

    /// The server never applied the report, so the next report carries its time too.
    @Test func anUnappliedSyncIsResentOnce() async throws {
        let (s, model, client) = try Self.modelHarness()
        let lost = ReconciliationSessionModel.Request(.unapplied)
        defer { lost.release() }
        lost.release()
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15)
        await model.enqueue(lost, for: .sync)
        await s.play(for: 15)
        #expect(try await Self.serverTotal(model, client, s) == 15)

        await s.play(for: 15)
        #expect(Self.lookups(s) == 1)
        #expect(s.service.reports.map(\.timeListened) == [15, 15, 30])
        #expect(try await Self.serverTotal(model, client, s) == 45)

        // Reconciled, so the next report doesn't look the session up again.
        await s.play(for: 15)
        #expect(Self.lookups(s) == 1)
        #expect(try await Self.serverTotal(model, client, s) == 60)
    }

    /// Without the server's answer the time is dropped, never sent blind (it was applied here).
    @Test func aFailedLookupDropsTheTime() async throws {
        let (s, model, client) = try Self.modelHarness()
        let lost = ReconciliationSessionModel.Request(.appliedResponseLost)
        let lookup = ReconciliationSessionModel.Request(.unapplied)
        defer {
            lost.release()
            lookup.release()
        }
        lost.release()
        lookup.release()
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15)
        await model.enqueue(lost, for: .sync)
        await s.play(for: 15)
        #expect(try await Self.serverTotal(model, client, s) == 30)

        await model.enqueue(lookup, for: .lookup)
        await s.play(for: 15)
        #expect(Self.lookups(s) == 1)
        #expect(s.service.reports.map(\.timeListened) == [15, 15, 15])
        #expect(try await Self.serverTotal(model, client, s) == 45)
    }

    /// A resent snapshot that fails ambiguously again isn't resent a second time.
    @Test func aResendIsNotResentAgain() async throws {
        let (s, model, client) = try Self.modelHarness()
        let first = ReconciliationSessionModel.Request(.unapplied)
        let second = ReconciliationSessionModel.Request(.unapplied)
        defer {
            first.release()
            second.release()
        }
        first.release()
        second.release()
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15)
        await model.enqueue(first, for: .sync)
        await model.enqueue(second, for: .sync)
        await s.play(for: 30)
        #expect(s.service.reports.map(\.timeListened) == [15, 15, 30])
        #expect(try await Self.serverTotal(model, client, s) == 15)

        // Of the unapplied 30 s, the 15 s already resent once is dropped.
        await s.play(for: 15)
        #expect(Self.lookups(s) == 2)
        #expect(s.service.reports.map(\.timeListened) == [15, 15, 30, 30])
        #expect(try await Self.serverTotal(model, client, s) == 45)
    }

    /// A total matching neither outcome drops the snapshot and adopts the server's total, so the
    /// next reconciliation compares against it.
    @Test func anUndecidableTotalDropsTheTimeAndAdoptsTheServers() async throws {
        let s = try SyncHarness()
        func session(_ listened: Double) -> Result<PlaybackSession, APIError> {
            .success(PlaybackSession(id: "x", libraryItemId: "a", mediaType: .book, timeListening: listened))
        }
        s.service.state.withLock {
            $0.syncErrors = [nil, .timedOut, nil, .timedOut]
            $0.lookupReplies = [session(22), session(37)]
        }
        await s.coordinator.play(itemID: "a")
        await s.play(for: 30)

        // 22 s is neither 15 (not applied) nor 30 (applied): nothing extra is sent.
        await s.play(for: 15)
        #expect(s.service.reports.map(\.timeListened) == [15, 15, 15])

        // Acknowledged 22 + 15 = 37 matches "not applied", so the 15 s ride along.
        await s.play(for: 30)
        #expect(Self.lookups(s) == 2)
        #expect(s.service.reports.map(\.timeListened) == [15, 15, 15, 15, 30])
    }
}
