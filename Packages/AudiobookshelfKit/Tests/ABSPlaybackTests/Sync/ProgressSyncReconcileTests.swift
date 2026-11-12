import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSData
@testable import ABSPlayback

/// An ambiguous `/sync` keeps its listening time until `GET /api/session/:id` shows whether the
/// server applied it (#381). The lookup waits ``ProgressSyncer/reconcileDelay``, 30 s here;
/// reports go out every 15 s.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProgressSyncReconcileTests {
    /// A harness whose session and progress services share one session model.
    private static func modelHarness() throws -> (SyncHarness, ReconciliationSessionModel, SessionModelClient) {
        let s = try SyncHarness()
        s.syncer.reconcileDelay = 30
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

    /// The client gives up on a `/sync` whose application the server holds past the lookup the
    /// next report would have made: the lookup waits, then sees it applied, so it isn't resent.
    @Test func lateCompletingSyncIsCountedOnce() async throws {
        let (s, model, client) = try Self.modelHarness()
        let late = ReconciliationSessionModel.Request()
        defer { late.release() }
        late.enter.open()
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15)
        await model.enqueue(late, for: .sync)
        s.service.state.withLock { $0.abandonedSyncs = [late] }

        // t = 30: the report times out while the server still holds it.
        await s.play(for: 15)
        #expect(s.service.log.contains("sync 2 timed out"))

        // t = 45: inside the delay, the report carries only new time and looks nothing up.
        await s.play(for: 15)
        #expect(Self.lookups(s) == 0)
        #expect(try await Self.serverTotal(model, client, s) == 30)

        // The server applies the held request after that report.
        late.apply.open()
        late.respond.open()
        await late.completed.wait()
        #expect(try await Self.serverTotal(model, client, s) == 45)

        // t = 60: the lookup finds it applied, so only the new 15 s go out.
        await s.play(for: 15)
        #expect(Self.lookups(s) == 1)
        #expect(s.service.reports.map(\.timeListened) == [15, 15, 15, 15])
        #expect(try await Self.serverTotal(model, client, s) == 60)
    }

    /// The server never applied the report, so the first report after the delay carries it too.
    @Test func anUnappliedSyncIsResentOnce() async throws {
        let (s, model, client) = try Self.modelHarness()
        let lost = ReconciliationSessionModel.Request(.unapplied)
        defer { lost.release() }
        lost.release()
        await s.coordinator.play(itemID: "a")
        await s.play(for: 15)
        await model.enqueue(lost, for: .sync)
        await s.play(for: 30)
        #expect(Self.lookups(s) == 0)
        #expect(try await Self.serverTotal(model, client, s) == 30)

        await s.play(for: 15)
        #expect(Self.lookups(s) == 1)
        #expect(s.service.reports.map(\.timeListened) == [15, 15, 15, 30])
        #expect(try await Self.serverTotal(model, client, s) == 60)

        // Reconciled, so the next report doesn't look the session up again.
        await s.play(for: 15)
        #expect(Self.lookups(s) == 1)
        #expect(try await Self.serverTotal(model, client, s) == 75)
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
        await s.play(for: 30)
        #expect(try await Self.serverTotal(model, client, s) == 45)

        await model.enqueue(lookup, for: .lookup)
        await s.play(for: 15)
        #expect(Self.lookups(s) == 1)
        #expect(s.service.reports.map(\.timeListened) == [15, 15, 15, 15])
        #expect(try await Self.serverTotal(model, client, s) == 60)
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
        await s.play(for: 30)
        await model.enqueue(second, for: .sync)
        await s.play(for: 15)
        #expect(s.service.reports.map(\.timeListened) == [15, 15, 15, 30])
        #expect(try await Self.serverTotal(model, client, s) == 30)

        // t = 90: of the unapplied 30 s, the 15 s already resent once is dropped.
        await s.play(for: 30)
        #expect(Self.lookups(s) == 2)
        #expect(s.service.reports.map(\.timeListened) == [15, 15, 15, 30, 15, 30])
        #expect(try await Self.serverTotal(model, client, s) == 75)
    }

    /// Recovered time a failed evidence save leaves pending is still not resent twice.
    @Test func recoveredTimeSurvivesAFailedPreparation() async throws {
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
        await s.play(for: 30)

        // t = 60: reconciled, but the report's evidence save fails, so nothing is sent.
        let store = s.store
        s.syncer.beforeSessionAudioPreparation = {
            await store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        }
        await s.play(for: 15)
        s.syncer.beforeSessionAudioPreparation = nil
        #expect(Self.lookups(s) == 1)
        #expect(s.service.reports.map(\.timeListened) == [15, 15, 15])

        // t = 75: the pending 30 s (15 recovered) and 15 new fail ambiguously.
        await model.enqueue(second, for: .sync)
        await s.play(for: 15)
        #expect(s.service.reports.map(\.timeListened) == [15, 15, 15, 45])

        // t = 105: the recovered 15 s are dropped, not resent again.
        await s.play(for: 30)
        #expect(Self.lookups(s) == 2)
        #expect(s.service.reports.map(\.timeListened) == [15, 15, 15, 45, 15, 45])
        #expect(try await Self.serverTotal(model, client, s) == 90)
    }

    /// Recovered time restored after a report that never reached the server is still not resent
    /// twice.
    @Test func recoveredTimeSurvivesAnUndeliveredReport() async throws {
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
        await s.play(for: 30)

        // t = 60: the report carrying the recovered 15 s can't connect, so its time is restored.
        s.service.state.withLock { $0.syncErrors = [.network(.cannotConnectToHost)] }
        await s.play(for: 15)
        #expect(Self.lookups(s) == 1)
        #expect(s.service.reports.map(\.timeListened) == [15, 15, 15, 30])

        // t = 75: the restored 30 s and 15 new fail ambiguously.
        await model.enqueue(second, for: .sync)
        await s.play(for: 15)
        #expect(s.service.reports.map(\.timeListened) == [15, 15, 15, 30, 45])

        // t = 105: the recovered 15 s are dropped, not resent again.
        await s.play(for: 30)
        #expect(Self.lookups(s) == 2)
        #expect(s.service.reports.map(\.timeListened) == [15, 15, 15, 30, 45, 15, 45])
        #expect(try await Self.serverTotal(model, client, s) == 90)
    }

    /// A second ambiguous failure before the first is reconciled merges into it: neither was
    /// applied, so both are resent.
    @Test func ambiguousFailuresMerge() async throws {
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
        await s.play(for: 45)
        #expect(Self.lookups(s) == 0)

        // t = 75: 30 s after the second failure.
        await s.play(for: 15)
        #expect(Self.lookups(s) == 1)
        #expect(s.service.reports.map(\.timeListened) == [15, 15, 15, 15, 45])
        #expect(try await Self.serverTotal(model, client, s) == 75)
    }

    /// A total matching neither outcome drops the snapshot and adopts the server's total, so the
    /// next reconciliation compares against it.
    @Test func anUndecidableTotalDropsTheTimeAndAdoptsTheServers() async throws {
        let s = try SyncHarness()
        s.syncer.reconcileDelay = 30
        func session(_ listened: Double) -> Result<PlaybackSession, APIError> {
            .success(PlaybackSession(id: "x", libraryItemId: "a", mediaType: .book, timeListening: listened))
        }
        s.service.state.withLock {
            $0.syncErrors = [nil, .timedOut, nil, nil, .timedOut]
            $0.lookupReplies = [session(22), session(52)]
        }
        await s.coordinator.play(itemID: "a")

        // t = 60: 22 s is neither 30 (not applied) nor 45 (applied): nothing extra is sent.
        await s.play(for: 60)
        #expect(Self.lookups(s) == 1)
        #expect(s.service.reports.map(\.timeListened) == [15, 15, 15, 15])

        // t = 105: acknowledged 22 + 15 + 15 = 52 matches "not applied", so the 15 s ride along.
        await s.play(for: 45)
        #expect(Self.lookups(s) == 2)
        #expect(s.service.reports.map(\.timeListened) == [15, 15, 15, 15, 15, 15, 30])
    }
}
