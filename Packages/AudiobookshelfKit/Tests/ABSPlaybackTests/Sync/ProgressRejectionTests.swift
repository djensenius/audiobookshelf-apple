import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSData
@testable import ABSPlayback

/// A PATCH rejected for good stops being retried, and stops retaining its connection, until
/// the row is edited again (#171, L10).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProgressRejectionTests {
    private static func status(_ code: Int) -> APIError { .http(status: code, message: nil) }

    private func edit(_ s: SyncHarness, _ time: Double) async throws {
        try await s.store.recordEdit(
            ProgressEdit(audio: .init(currentTime: time, duration: 3600, progress: time / 3600)), for: s.h.key("a"),
            now: s.h.clock.now)
    }

    @Test(arguments: [
        (APIError.notFound, "rejected 404"), (.http(status: 400, message: nil), "rejected 400"),
        (.http(status: 404, message: nil), "rejected 404"), (.http(status: 410, message: nil), "rejected 410"),
        (.http(status: 422, message: nil), "rejected 422"),
        (.forbidden(message: "User does not have access to this library item"), "rejected 403"),
    ])
    func permanentRejectionIsNotRetriedUntilTheNextEdit(error: APIError, recorded: String) async throws {
        let s = try SyncHarness()
        s.service.state.withLock { $0.patchErrors = [error] }
        try await edit(s, 50)

        await s.syncer.drainPendingProgress()
        // A rejection settles the row, so the drain isn't counted as failed.
        #expect(s.syncer.drainWake == nil && s.syncer.drainFailures == 0)

        let row = try #require(try await s.store.progress(for: s.h.key("a")))
        #expect(!row.needsServerSync)
        #expect(row.lastSyncError == recorded)
        #expect(row.currentTime == 50)
        #expect(try await s.store.pendingSync(for: s.h.connectionID).isEmpty)
        await s.syncer.drainPendingProgress()
        #expect(s.service.patches == [.init(itemID: "a", update: SyncHarness.audio(50))])

        s.h.clock.advance(by: 1)
        try await edit(s, 60)
        await s.syncer.drainPendingProgress()
        #expect(s.service.patches.map(\.update) == [SyncHarness.audio(50), SyncHarness.audio(60)])
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == false)
    }

    @Test(arguments: [401, 403, 408, 409, 413, 429, 500])
    func otherStatusesStayRetried(code: Int) async throws {
        #expect(!ProgressSyncer.isPermanent(Self.status(code)))
        let s = try SyncHarness()
        s.service.state.withLock { $0.patchErrors = [Self.status(code)] }
        try await edit(s, 50)

        await s.syncer.drainPendingProgress()
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == true)
        await s.syncer.drainPendingProgress()

        #expect(s.service.patches.count == 2)
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == false)
    }

    @Test func classification() {
        #expect(ProgressSyncer.isPermanent(APIError.notFound))
        for code in [400, 404, 410, 422] { #expect(ProgressSyncer.isPermanent(Self.status(code))) }
        for error in [APIError.timedOut, .forbidden(message: nil), .sessionExpired, .invalidURL, .decoding("x")] {
            #expect(!ProgressSyncer.isPermanent(error))
        }
        #expect(!ProgressSyncer.isPermanent(CancellationError()))
    }

    /// Only Audiobookshelf's exact no-access body makes a progress PATCH's 403 permanent; other
    /// requests' 403s, including that one, stay retryable (#680).
    @Test func forbiddenClassification() {
        let noAccess = "User does not have access to this library item"
        #expect(ProgressSyncer.patchRejectionStatus(APIError.forbidden(message: noAccess)) == 403)
        #expect(ProgressSyncer.patchRejectionStatus(APIError.forbidden(message: " \(noAccess)\n")) == 403)
        #expect(!ProgressSyncer.isPermanent(APIError.forbidden(message: noAccess)))
        for message in [nil, "Forbidden", "User does not have access to this library", noAccess.lowercased()] {
            #expect(ProgressSyncer.patchRejectionStatus(APIError.forbidden(message: message)) == nil)
        }
        #expect(ProgressSyncer.patchRejectionStatus(APIError.unauthorized(message: noAccess)) == nil)
        #expect(ProgressSyncer.patchRejectionStatus(APIError.http(status: 410, message: nil)) == 410)
    }

    /// A 403 without Audiobookshelf's exact no-access body is retried on the next drain (#680).
    @Test(arguments: [nil, "Forbidden"] as [String?])
    func otherForbiddenPatchesStayRetried(message: String?) async throws {
        let s = try SyncHarness()
        s.service.state.withLock { $0.patchErrors = [.forbidden(message: message)] }
        try await edit(s, 50)

        await s.syncer.drainPendingProgress()
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == true)
        #expect(s.syncer.drainWake != nil)

        await s.syncer.drainPendingProgress()
        #expect(s.service.patches.count == 2)
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == false)
    }

    /// A rejection whose cleanup can't be saved keeps its send in flight: the next drain saves
    /// the cleanup without PATCHing the same values again, and a new edit is still sent, whether
    /// it lands before that retry or after it.
    @Test(arguments: [false, true])
    func failedRejectionCleanupIsRetriedWithoutAnotherPatch(editBeforeRetry: Bool) async throws {
        let s = try SyncHarness()
        let started = Gate()
        let response = Gate()
        s.service.state.withLock {
            $0.patchErrors = [.notFound]
            $0.patchStarted = started
            $0.patchGates = [response]
        }
        try await edit(s, 50)
        let drain = Task { await s.syncer.drainPendingProgress() }
        await started.wait()
        await s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        response.open()
        await drain.value
        let failed = try #require(try await s.store.progress(for: s.h.key("a")))
        #expect(failed.needsServerSync && failed.lastSyncError == nil)

        if editBeforeRetry {
            s.h.clock.advance(by: 1)
            try await edit(s, 60)
        }
        await s.syncer.drainPendingProgress()
        if !editBeforeRetry {
            let cleaned = try #require(try await s.store.progress(for: s.h.key("a")))
            #expect(!cleaned.needsServerSync && cleaned.lastSyncError == "rejected 404")
            #expect(s.service.patches.map(\.update) == [SyncHarness.audio(50)])
            s.h.clock.advance(by: 1)
            try await edit(s, 60)
            await s.syncer.drainPendingProgress()
        }

        #expect(s.service.patches.map(\.update) == [SyncHarness.audio(50), SyncHarness.audio(60)])
        #expect(try await s.store.progress(for: s.h.key("a"))?.needsServerSync == false)
    }

    /// The syncer that failed to save a rejection's cleanup retires; a replacement sharing the
    /// store saves it without PATCHing the rejected values, then sends a later edit.
    @Test func aReplacementSyncerFinishesAFailedRejectionCleanup() async throws {
        let s = try SyncHarness()
        let started = Gate()
        let response = Gate()
        s.service.state.withLock {
            $0.patchErrors = [.notFound]
            $0.patchStarted = started
            $0.patchGates = [response]
        }
        try await edit(s, 50)
        let drain = Task { await s.syncer.drainPendingProgress() }
        await started.wait()
        await s.store.failNextCommit(with: CocoaError(.fileWriteNoPermission))
        response.open()
        await drain.value
        s.syncer.detach()

        let clock = s.h.clock
        let service = StubProgressSyncService(serverConnectionID: s.h.connectionID)
        let replacement = ProgressSyncer(
            source: s.coordinator, service: service, store: s.store,
            clock: ProgressSyncClock(now: { clock.now }, uptime: { clock.now.timeIntervalSince1970 }),
            tickInterval: 0.5)
        await replacement.drainPendingProgress()

        let cleaned = try #require(try await s.store.progress(for: s.h.key("a")))
        #expect(!cleaned.needsServerSync && cleaned.lastSyncError == "rejected 404")
        #expect(service.patches.isEmpty)
        s.h.clock.advance(by: 1)
        try await edit(s, 60)
        await replacement.drainPendingProgress()
        #expect(service.patches.map(\.update) == [SyncHarness.audio(60)])
        #expect(s.service.patches.map(\.update) == [SyncHarness.audio(50)])
        replacement.detach()
    }

    /// An edit made while the rejected PATCH was in flight is still sent.
    @Test func editDuringTheRejectedPatchIsSent() async throws {
        let s = try SyncHarness()
        let started = Gate()
        let response = Gate()
        s.service.state.withLock {
            $0.patchErrors = [.notFound]
            $0.patchStarted = started
            $0.patchGates = [response]
        }
        try await edit(s, 50)
        let drain = Task { await s.syncer.drainPendingProgress() }
        await started.wait()
        s.h.clock.advance(by: 1)
        try await edit(s, 60)
        response.open()
        await drain.value

        let row = try #require(try await s.store.progress(for: s.h.key("a")))
        #expect(row.lastSyncError == "rejected 404")
        #expect(row.needsServerSync)
        await s.syncer.drainPendingProgress()
        #expect(s.service.patches.map(\.update) == [SyncHarness.audio(50), SyncHarness.audio(60)])
    }
}
