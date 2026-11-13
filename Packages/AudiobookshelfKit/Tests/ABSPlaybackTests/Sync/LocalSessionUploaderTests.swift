import ABSCore
import ABSData
import Foundation
import Synchronization
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// Uploading pending local sessions with `local-all`, falling back to `/local` (#74).
@Suite(.timeLimit(.minutes(1)))
struct LocalSessionUploaderTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let connection = UUID()
    private let store: LocalProgressStore
    private let sleeps = SleepLog()

    init() throws {
        store = try LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
    }

    @Test func batchesTheConnectionsSessionsIntoOneLocalAllRequest() async throws {
        let first = try await save(minute: 0)
        let second = try await save(minute: 1)
        let other = try await save(minute: 2, connection: UUID())
        let service = StubUploadService()

        let report = await uploader(service).sync()

        #expect(service.batches == [[first.id, second.id]])
        #expect(service.deviceIDs == ["device"])
        #expect(service.singles.isEmpty)
        #expect(report.results == [first.id: .success, second.id: .success])
        #expect(report.deleted == [first.id, second.id] && report.isComplete)
        #expect(try await store.pendingSessions(for: connection).isEmpty)
        #expect(try await store.session(id: other.id) != nil)
    }

    @Test func sendsALargeBacklogInBatches() async throws {
        var ids: [String] = []
        for minute in 0..<5 { ids.append(try await save(minute: minute).id) }
        let service = StubUploadService()

        let report = await uploader(service, batchSize: 2).sync()

        #expect(service.batches == [Array(ids[0..<2]), Array(ids[2..<4]), [ids[4]]])
        #expect(report.deleted == Set(ids) && report.isComplete)
    }

    /// Only a session's own result deletes it (ADR 0003): a failure is counted, and a missing
    /// result is kept for the next sync.
    @Test func keepsASessionTheServerRejectedOrDidNotAnswer() async throws {
        let rejected = try await save(minute: 0)
        let unanswered = try await save(minute: 1)
        let accepted = try await save(minute: 2)
        let service = StubUploadService(all: { _, _ in
            LocalSessionSyncResponse(results: [
                .init(id: rejected.id, success: false, progressSynced: nil, error: "Media item not found"),
                .init(id: accepted.id, success: true, progressSynced: true, error: nil),
            ])
        })

        let report = await uploader(service).sync()

        #expect(report.results == [rejected.id: .failure("Media item not found"), accepted.id: .success])
        #expect(report.deleted == [accepted.id] && report.isComplete)
        let kept = try #require(try await store.session(id: rejected.id))
        #expect(kept.uploadAttempts == 1 && kept.lastUploadError == "Media item not found")
        #expect(try await store.session(id: unanswered.id)?.uploadAttempts == 0)
    }

    @Test(arguments: [false, true])
    func keepsActiveSessionsUnlessItIsTheFirstSync(isFirstSync: Bool) async throws {
        let active = try await save(active: true, minute: 0)
        let closed = try await save(minute: 1)
        let service = StubUploadService()

        let report = await uploader(service).sync(isFirstSync: isFirstSync)

        #expect(service.batches == [[active.id, closed.id]])
        #expect(report.results == [active.id: .success, closed.id: .success])
        #expect(report.deleted == (isFirstSync ? [active.id, closed.id] : [closed.id]))
        let isKept = try await store.session(id: active.id) != nil
        #expect(isKept == !isFirstSync)
    }

    @Test func keepsASessionChangedDuringTheUploadAndSendsItAgain() async throws {
        let session = try await save()
        let entered = Gate()
        let release = Gate()
        let service = StubUploadService(all: { call, batch in
            if call == 1 {
                entered.open()
                await release.wait()
            }
            return .succeeding(batch)
        })
        let uploader = uploader(service)

        let pass = Task { await uploader.sync() }
        await entered.wait()
        var changed = session
        changed.currentTime = 120
        changed.updatedAt += 60
        try await store.saveSession(changed)
        release.open()

        let report = await pass.value
        #expect(report.results == [session.id: .success] && report.deleted.isEmpty)
        #expect(await uploader.sync().deleted == [session.id])
        #expect(service.batches == [[session.id], [session.id]])
        #expect(service.currentTimes.last == [120])
    }

    @Test(arguments: [APIError.notFound, .http(status: 405, message: nil)])
    func fallsBackToOneRequestPerSessionWithoutLocalAll(error: APIError) async throws {
        let accepted = try await save(minute: 0)
        let rejected = try await save(minute: 1)
        let service = StubUploadService(
            all: { _, _ in throw error },
            one: { _, payload in
                if payload.id == rejected.id { throw APIError.http(status: 500, message: "Media item not found") }
            })
        let uploader = uploader(service)

        let report = await uploader.sync()

        #expect(service.batches.count == 1)
        #expect(service.singles == [accepted.id, rejected.id])
        #expect(service.singleDeviceIDs == ["device", "device"])
        #expect(report.results == [accepted.id: .success, rejected.id: .failure("Media item not found")])
        #expect(report.deleted == [accepted.id] && report.isComplete)
        #expect(try await store.session(id: rejected.id)?.uploadAttempts == 1)
        #expect(sleeps.delays.isEmpty)

        // The uploader remembers the server has no `local-all`.
        await uploader.sync()
        #expect(service.batches.count == 1)
        #expect(service.singles == [accepted.id, rejected.id, rejected.id])
    }

    @Test func retriesAnUnansweredUploadAfterABackoff() async throws {
        let session = try await save()
        let service = StubUploadService(all: { call, batch in
            switch call {
            case 1: throw APIError.timedOut
            case 2: throw APIError.http(status: 503, message: nil)
            default: return .succeeding(batch)
            }
        })

        let report = await uploader(service).sync()

        #expect(service.batches == [[session.id], [session.id], [session.id]])
        #expect(sleeps.delays == [2, 4])
        #expect(report.deleted == [session.id] && report.isComplete)
    }

    /// An upload that got no answer says nothing about its sessions, so none is counted.
    @Test func givesUpAfterTheLastAttemptWithoutCountingAFailure() async throws {
        let session = try await save()
        let service = StubUploadService(all: { _, _ in throw APIError.network(.notConnectedToInternet) })

        let report = await uploader(service).sync()

        #expect(service.batches.count == LocalSessionUploader.maxAttempts)
        #expect(sleeps.delays == [2, 4])
        #expect(!report.isComplete && report.results.isEmpty)
        let kept = try #require(try await store.session(id: session.id))
        #expect(kept.uploadAttempts == 0 && kept.lastUploadError == nil)
    }

    /// A declined cross-origin redirect isn't the server's answer, from `local-all` or `/local`:
    /// the pass ends without retrying, and every session stays pending and uncounted.
    @Test(arguments: [false, true]) func aRefusedRedirectKeepsEverySession(fromFallback: Bool) async throws {
        let first = try await save(minute: 0)
        let second = try await save(minute: 1)
        let refused = APIError.redirectRefused(status: 307)
        let service = StubUploadService(
            all: { _, _ in
                if fromFallback { throw APIError.notFound }
                throw refused
            },
            one: { _, _ in throw refused })

        let report = await uploader(service).sync()

        #expect(service.batches.count == 1)
        #expect(service.singles == (fromFallback ? [first.id] : []))
        #expect(sleeps.delays.isEmpty)
        #expect(!report.isComplete && report.results.isEmpty && report.deleted.isEmpty)
        for session in [first, second] {
            let kept = try #require(try await store.session(id: session.id))
            #expect(kept.uploadAttempts == 0 && kept.lastUploadError == nil)
        }
    }

    @Test func aRetriedFallbackResumesAfterTheLastAnsweredSession() async throws {
        let first = try await save(minute: 0)
        let second = try await save(minute: 1)
        let third = try await save(minute: 2)
        let service = StubUploadService(
            all: { _, _ in throw APIError.notFound },
            one: { call, _ in if call == 2 { throw APIError.timedOut } })

        let report = await uploader(service).sync()

        #expect(service.singles == [first.id, second.id, second.id, third.id])
        #expect(sleeps.delays == [2])
        #expect(report.deleted == [first.id, second.id, third.id] && report.isComplete)
    }

    /// Passes never overlap: a sync during one waits for it instead of sending the same sessions
    /// alongside it, then sends what changed meanwhile; callers arriving meanwhile share that pass.
    @Test func aSyncDuringAPassWaitsForItThenSendsWhatChanged() async throws {
        let first = try await save(minute: 0)
        let second = try await save(minute: 1)
        let entered = Gate()
        let release = Gate()
        let service = StubUploadService(all: { call, batch in
            if call == 1 {
                entered.open()
                await release.wait()
            }
            return .succeeding(batch)
        })
        let uploader = uploader(service)

        let running = Task { await uploader.sync() }
        await entered.wait()
        var changed = second
        changed.currentTime = 120
        changed.updatedAt += 60
        try await store.saveSession(changed)
        let queued = Task { await uploader.sync() }
        #expect(await pollUntil { await uploader.hasQueuedPass })
        let joining = Task { await uploader.sync() }
        release.open()

        #expect(await running.value.deleted == [first.id])
        #expect(await queued.value.deleted == [second.id])
        _ = await joining.value
        #expect(service.batches == [[first.id, second.id], [second.id]])
        #expect(service.currentTimes.last == [120])
    }

    @Test func doesNotResendAnAcknowledgedActiveSessionUntilItChanges() async throws {
        var session = try await save(active: true)
        let service = StubUploadService()
        let uploader = uploader(service)

        await uploader.sync()
        await uploader.sync()
        #expect(service.batches == [[session.id]])

        session.currentTime += 60
        session.updatedAt += 60
        try await store.saveSession(session)
        await uploader.sync()
        #expect(service.batches.count == 2)

        // Closed without a newer `updatedAt`: sent again, so the store can delete it.
        session.isActive = false
        try await store.saveSession(session)
        #expect(await uploader.sync().deleted == [session.id])
        #expect(service.batches.count == 3)
    }

    @Test func anInvalidSessionCountsAsAFailureWithoutBlockingTheOthers() async throws {
        let invalid = try await save(id: "play_local_1", minute: 0)
        let valid = try await save(minute: 1)
        let service = StubUploadService()

        let report = await uploader(service).sync()

        #expect(service.batches == [[valid.id]])
        #expect(report.deleted == [valid.id])
        #expect(report.results[valid.id] == .success)
        guard case .failure = report.results[invalid.id] else {
            Issue.record(
                "Expected a failure for the invalid session, got \(String(describing: report.results[invalid.id]))")
            return
        }
        #expect(try await store.session(id: invalid.id)?.uploadAttempts == 1)
    }

    @Test func cancelStopsAPassWaitingToRetry() async throws {
        let session = try await save()
        let failed = Gate()
        let service = StubUploadService(all: { _, _ in
            failed.open()
            throw APIError.timedOut
        })
        let uploader = LocalSessionUploader(
            serverConnectionID: connection, store: store, service: service, deviceIdentifiers: UploaderDevice(),
            sleep: { try await Task.sleep(for: .seconds($0 * 3600)) })

        let pass = Task { await uploader.sync() }
        await failed.wait()
        await uploader.cancel()

        let report = await pass.value
        #expect(!report.isComplete && service.batches.count == 1)
        #expect(try await store.session(id: session.id)?.uploadAttempts == 0)
    }

    /// A `/local` call that returns normally after a cancel ends the pass: the other sessions
    /// aren't sent, and the answer it got is still settled.
    @Test func cancelDuringAFallbackUploadSendsNoMoreButSettlesItsAnswer() async throws {
        let first = try await save(minute: 0)
        let second = try await save(minute: 1)
        let third = try await save(minute: 2)
        let entered = Gate()
        let release = Gate()
        let service = StubUploadService(
            all: { _, _ in throw APIError.notFound },
            one: { call, _ in
                guard call == 1 else { return }
                entered.open()
                await release.wait()
            })
        let uploader = uploader(service)

        let pass = Task { await uploader.sync() }
        await entered.wait()
        await uploader.cancel()
        release.open()

        let report = await pass.value
        #expect(service.singles == [first.id])
        #expect(report.results == [first.id: .success] && report.deleted == [first.id] && !report.isComplete)
        #expect(try await store.session(id: first.id) == nil)
        for session in [second, third] {
            #expect(try await store.session(id: session.id)?.uploadAttempts == 0)
        }
    }

    /// A store read that returns normally after a cancel ends the pass before `local-all`: nothing
    /// is sent or settled.
    @Test func cancelDuringThePendingReadSendsNothing() async throws {
        let first = try await save(minute: 0)
        let second = try await save(minute: 1)
        let entered = Gate()
        let release = Gate()
        let service = StubUploadService()
        let uploader = uploader(service)
        await uploader.setAfterPendingRead {
            entered.open()
            await release.wait()
        }

        let pass = Task { await uploader.sync() }
        await entered.wait()
        await uploader.cancel()
        release.open()

        let report = await pass.value
        #expect(service.batches.isEmpty && service.singles.isEmpty)
        #expect(!report.isComplete && report.results.isEmpty && report.deleted.isEmpty)
        for session in [first, second] {
            #expect(try await store.session(id: session.id)?.uploadAttempts == 0)
        }
    }

    // MARK: - Helpers

    private func uploader(_ service: StubUploadService, batchSize: Int = LocalSessionUploader.defaultBatchSize)
        -> LocalSessionUploader
    {
        let sleeps = sleeps
        return LocalSessionUploader(
            serverConnectionID: connection, store: store, service: service, deviceIdentifiers: UploaderDevice(),
            batchSize: batchSize, now: { Self.start.addingTimeInterval(86_400) }, sleep: { sleeps.record($0) })
    }

    /// Saves a pending session that began `minute` minutes after ``start``; sessions upload in
    /// that order.
    @discardableResult
    private func save(
        id: String = UUID().uuidString, active: Bool = false, minute: Int = 0, connection: UUID? = nil
    ) async throws -> PendingLocalSessionDTO {
        let startedAt = Self.start.addingTimeInterval(Double(minute) * 60)
        let session = PendingLocalSessionDTO(
            id: id, key: MediaKey(serverConnectionID: connection ?? self.connection, libraryItemId: "item"),
            userId: "user", mediaType: .book, displayTitle: "Title", duration: 3600, startTime: 0,
            startedAt: startedAt, updatedAt: startedAt.addingTimeInterval(30), timeListening: 30, currentTime: 30,
            isActive: active)
        try await store.saveSession(session)
        return session
    }
}

/// Polls `condition` every 10 ms for up to 10 s.
private func pollUntil(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<1_000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

private struct UploaderDevice: DeviceIdentifying {
    func deviceIdentifier() async -> String { "device" }
}

/// Records each requested wait without waiting.
private final class SleepLog: Sendable {
    private let state = Mutex<[TimeInterval]>([])

    var delays: [TimeInterval] { state.withLock { $0 } }
    func record(_ delay: TimeInterval) { state.withLock { $0.append(delay) } }
}

/// Records each upload and answers it with the test's handlers; `call` counts from 1 per endpoint.
private final class StubUploadService: LocalSessionUploadService {
    typealias AllHandler =
        @Sendable (_ call: Int, _ batch: LocalPlaybackSessionBatch) async throws ->
        LocalSessionSyncResponse
    typealias OneHandler = @Sendable (_ call: Int, _ session: LocalPlaybackSessionPayload) async throws -> Void

    private let requests = Mutex<(batches: [LocalPlaybackSessionBatch], singles: [LocalPlaybackSessionPayload])>(
        ([], []))
    private let all: AllHandler
    private let one: OneHandler

    init(all: @escaping AllHandler = { _, batch in .succeeding(batch) }, one: @escaping OneHandler = { _, _ in }) {
        self.all = all
        self.one = one
    }

    /// The session ids of each `local-all` request.
    var batches: [[String]] { requests.withLock { $0.batches.map { $0.sessions.map(\.id) } } }
    var currentTimes: [[Double]] { requests.withLock { $0.batches.map { $0.sessions.map(\.currentTime) } } }
    var deviceIDs: [String?] { requests.withLock { $0.batches.map(\.deviceInfo.deviceId) } }
    /// The session id of each `/local` request.
    var singles: [String] { requests.withLock { $0.singles.map(\.id) } }
    var singleDeviceIDs: [String?] { requests.withLock { $0.singles.map { $0.deviceInfo?.deviceId } } }

    func uploadAll(_ batch: LocalPlaybackSessionBatch) async throws -> LocalSessionSyncResponse {
        let call = requests.withLock {
            $0.batches.append(batch)
            return $0.batches.count
        }
        return try await all(call, batch)
    }

    func upload(_ session: LocalPlaybackSessionPayload) async throws {
        let call = requests.withLock {
            $0.singles.append(session)
            return $0.singles.count
        }
        try await one(call, session)
    }
}

extension LocalSessionSyncResponse {
    /// Every session in `batch` acknowledged.
    fileprivate static func succeeding(_ batch: LocalPlaybackSessionBatch) -> Self {
        Self(results: batch.sessions.map { .init(id: $0.id, success: true, progressSynced: true, error: nil) })
    }
}
