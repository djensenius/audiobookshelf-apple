import ABSAPI
import ABSCore
import ABSData
import Foundation
import os

private let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "LocalSessionUploader")

/// The server calls ``LocalSessionUploader`` makes for one connection.
/// ``APILocalSessionUploadService`` is the live implementation; tests use stubs.
public protocol LocalSessionUploadService: Sendable {
    /// `POST /api/session/local-all`: the server's result for each session it handled.
    func uploadAll(_ batch: LocalPlaybackSessionBatch) async throws -> LocalSessionSyncResponse
    /// `POST /api/session/local`. The server answers a session it can't apply (for example
    /// `Media item not found`) with a 500 carrying the reason.
    func upload(_ session: LocalPlaybackSessionPayload) async throws
}

/// ``LocalSessionUploadService`` over one connection's ``APIClient``.
public struct APILocalSessionUploadService: LocalSessionUploadService {
    private let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    public func uploadAll(_ batch: LocalPlaybackSessionBatch) async throws -> LocalSessionSyncResponse {
        try await client.send(SessionEndpoints.syncLocalAll(batch))
    }

    public func upload(_ session: LocalPlaybackSessionPayload) async throws {
        _ = try await client.send(SessionEndpoints.syncLocal(session))
    }
}

/// What one ``LocalSessionUploader/sync(isFirstSync:)`` pass did.
public struct LocalSessionUploadReport: Sendable, Equatable {
    /// The server's answer for each session, by id. A session that can't be made into a valid
    /// payload is never sent and is answered as a failure.
    public internal(set) var results: [String: SessionUploadResult] = [:]
    /// The sessions removed from the store: acknowledged and closed, or discarded after
    /// repeated failures.
    public internal(set) var deleted: Set<String> = []
    /// `false` when the pass stopped early: the server stayed unreachable after every attempt,
    /// refused the request (for example, the login expired), the store failed, or the pass was
    /// cancelled. Sessions left unanswered stay pending, with no failure counted.
    public internal(set) var isComplete = true
}

/// Uploads one connection's pending local listening sessions (ADR 0003) after a reconnect
/// (ADR 0007, decision 7).
///
/// A pass reads the connection's pending sessions, oldest first, and sends them in batches with
/// `POST /api/session/local-all`, which answers each session in `results`. A server without
/// `local-all` (404 or 405) gets one `POST /api/session/local` per session instead, for the rest
/// of this uploader's life. Answers are settled by
/// `LocalProgressStore.settleSessionUpload(sent:results:isFirstSync:now:)`: it deletes
/// acknowledged sessions but keeps active ones (except on the first sync after login) and those
/// changed during the upload, and counts failures toward discarding a session.
///
/// Active sessions are sent too, as in the legacy app, so the server gets offline progress
/// sooner. One the server acknowledged isn't sent again until it changes or closes.
///
/// A request that gets no answer (no connection, a timeout, 408, 429, or a `local-all` 5xx) is
/// retried after a backoff, up to ``maxAttempts`` times per pass, and never counts against its
/// sessions; the pass then stops and they wait for the next sync.
///
/// Passes never overlap, so no session is in two uploads at once: a sync during a pass waits
/// for it, then runs one more pass, shared by every caller that arrived meanwhile. Within a
/// pass, a session the server answered isn't sent again.
public actor LocalSessionUploader {
    /// A pass stops at this many unanswered requests; it waits 2 s before the first retry,
    /// doubling each time.
    public static let maxAttempts = 3
    /// The most sessions sent in one `local-all` request.
    public static let defaultBatchSize = 50

    /// The wait after `failures` unanswered requests: 2 s, doubling up to 64 s.
    static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        2 * Double(1 << min(max(failures - 1, 0), 5))
    }

    public nonisolated let serverConnectionID: UUID
    private let store: LocalProgressStore
    private let service: any LocalSessionUploadService
    private let deviceIdentifiers: any DeviceIdentifying
    private let batchSize: Int
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// Cleared once the server answers `local-all` with 404 or 405.
    private var supportsLocalAll = true
    /// The `updatedAt` of each active session the server acknowledged and the store kept.
    private var acknowledged: [String: Date] = [:]
    private var running: Task<LocalSessionUploadReport, Never>?
    /// The pass that runs after ``running``, shared by every caller that asked meanwhile.
    private var queued: Task<LocalSessionUploadReport, Never>?
    private var queuedIsFirstSync = false

    public init(
        serverConnectionID: UUID, store: LocalProgressStore, service: any LocalSessionUploadService,
        deviceIdentifiers: any DeviceIdentifying, batchSize: Int = LocalSessionUploader.defaultBatchSize,
        now: @escaping @Sendable () -> Date = { .now },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.serverConnectionID = serverConnectionID
        self.store = store
        self.service = service
        self.deviceIdentifiers = deviceIdentifiers
        self.batchSize = max(batchSize, 1)
        self.now = now
        self.sleep = sleep
    }

    /// Uploads the connection's pending sessions, as described in ``LocalSessionUploader``.
    ///
    /// - Parameter isFirstSync: The first sync after login, which deletes acknowledged active
    ///   sessions too (ADR 0003).
    /// - Returns: What the pass this call ran or joined did.
    @discardableResult
    public func sync(isFirstSync: Bool = false) async -> LocalSessionUploadReport {
        if let queued {
            queuedIsFirstSync = queuedIsFirstSync || isFirstSync
            return await queued.value
        }
        guard let running else {
            let pass = Task { await self.runPass(isFirstSync: isFirstSync) }
            running = pass
            return await pass.value
        }
        queuedIsFirstSync = isFirstSync
        let pass = Task {
            _ = await running.value
            return await self.runQueuedPass()
        }
        queued = pass
        return await pass.value
    }

    /// Stops the running pass and the queued one; sessions they didn't settle stay pending.
    public func cancel() {
        running?.cancel()
        queued?.cancel()
    }

    /// Whether a pass waits for the running one (tests).
    var hasQueuedPass: Bool { queued != nil }

    private func runQueuedPass() async -> LocalSessionUploadReport {
        running = queued
        queued = nil
        let isFirstSync = queuedIsFirstSync
        queuedIsFirstSync = false
        return await runPass(isFirstSync: isFirstSync)
    }

    private func runPass(isFirstSync: Bool) async -> LocalSessionUploadReport {
        defer { running = nil }
        var report = LocalSessionUploadReport()
        let deviceInfo = PlaybackDeviceInfo.make(deviceID: await deviceIdentifiers.deviceIdentifier())
        guard deviceInfo.deviceId?.isEmpty == false else {
            logger.error("Not uploading local sessions: no device ID")
            report.isComplete = false
            return report
        }
        // Every session this pass settled, so none is sent twice.
        var settled: Set<String> = []
        var failures = 0
        while !Task.isCancelled {
            let pending: [PendingLocalSessionDTO]
            do {
                pending = try await store.pendingSessions(for: serverConnectionID)
            } catch {
                logger.error("Reading pending local sessions failed: \(String(describing: error), privacy: .public)")
                break
            }
            let pendingIDs = Set(pending.map(\.id))
            acknowledged = acknowledged.filter { pendingIDs.contains($0.key) }
            let due = pending.filter { !settled.contains($0.id) && !isAcknowledged($0, isFirstSync: isFirstSync) }
            guard !due.isEmpty else { return report }

            let attempt = await upload(Array(due.prefix(batchSize)), deviceInfo: deviceInfo)
            if !attempt.sent.isEmpty {
                guard await settle(attempt, isFirstSync: isFirstSync, into: &report) else { break }
                settled.formUnion(attempt.sent.keys)
            }
            switch attempt.stop {
            case nil:
                continue
            case .unsupported:
                logger.notice("The server has no local-all; uploading local sessions one at a time")
                supportsLocalAll = false
            case .end:
                report.isComplete = false
                return report
            case .retry:
                failures += 1
                // A failed sleep was cancelled.
                guard failures < Self.maxAttempts, (try? await sleep(Self.retryDelay(afterFailures: failures))) != nil
                else {
                    report.isComplete = false
                    return report
                }
            }
        }
        report.isComplete = false
        return report
    }

    /// An active session the server acknowledged that hasn't changed since. One closed since is
    /// sent again, so the store can delete it.
    private func isAcknowledged(_ session: PendingLocalSessionDTO, isFirstSync: Bool) -> Bool {
        !isFirstSync && session.isActive && acknowledged[session.id] == session.updatedAt
    }

    /// Sends `sessions`; one that can't be made into a valid payload is answered as a failure
    /// instead.
    private func upload(_ sessions: [PendingLocalSessionDTO], deviceInfo: DeviceInfo) async -> Attempt {
        var invalid = Attempt()
        var payloads: [Payload] = []
        for session in sessions {
            do {
                let payload = try LocalPlaybackSessionPayload(
                    session: PlaybackSession(pending: session), deviceInfo: deviceInfo)
                payloads.append(Payload(updatedAt: session.updatedAt, body: payload))
            } catch {
                logger.error(
                    "Local session \(session.id, privacy: .public) can't be uploaded: \(String(describing: error), privacy: .public)"
                )
                invalid.answer(session.id, sent: session.updatedAt, .failure("Invalid session: \(error)"))
            }
        }
        guard !payloads.isEmpty else { return invalid }
        var attempt: Attempt
        if supportsLocalAll {
            attempt = await uploadAll(payloads, deviceInfo: deviceInfo)
        } else {
            attempt = await uploadEach(payloads)
        }
        attempt.sent.merge(invalid.sent) { sent, _ in sent }
        attempt.results.merge(invalid.results) { result, _ in result }
        return attempt
    }

    private func uploadAll(_ payloads: [Payload], deviceInfo: DeviceInfo) async -> Attempt {
        var attempt = Attempt()
        let response: LocalSessionSyncResponse
        do {
            let batch = try LocalPlaybackSessionBatch(sessions: payloads.map(\.body), deviceInfo: deviceInfo)
            response = try await service.uploadAll(batch)
        } catch {
            attempt.stop = Self.batchStop(for: error)
            return attempt
        }
        // Every session sent is settled; one without a result counts as unanswered (ADR 0003).
        for payload in payloads { attempt.sent[payload.body.id] = payload.updatedAt }
        for result in response.results where attempt.sent[result.id] != nil && attempt.results[result.id] == nil {
            attempt.results[result.id] = result.success ? .success : .failure(result.error)
        }
        return attempt
    }

    /// `POST /api/session/local` for each session, oldest first, until one gets no answer.
    private func uploadEach(_ payloads: [Payload]) async -> Attempt {
        var attempt = Attempt()
        for payload in payloads {
            do {
                try await service.upload(payload.body)
                attempt.answer(payload.body.id, sent: payload.updatedAt, .success)
            } catch {
                switch Self.answer(to: error) {
                case .result(let result):
                    attempt.answer(payload.body.id, sent: payload.updatedAt, result)
                case .stop(let stop):
                    attempt.stop = stop
                    return attempt
                }
            }
        }
        return attempt
    }

    /// Saves the attempt's answers; `false` when the store failed.
    private func settle(_ attempt: Attempt, isFirstSync: Bool, into report: inout LocalSessionUploadReport) async
        -> Bool
    {
        let deleted: Set<String>
        do {
            deleted = try await store.settleSessionUpload(
                sent: attempt.sent, results: attempt.results, isFirstSync: isFirstSync, now: now())
        } catch {
            logger.error("Settling local session uploads failed: \(String(describing: error), privacy: .public)")
            return false
        }
        for (id, result) in attempt.results {
            report.results[id] = result
            acknowledged[id] = result == .success && !deleted.contains(id) ? attempt.sent[id] : nil
        }
        report.deleted.formUnion(deleted)
        return true
    }

    /// How a failed `local-all` ends the attempt; it settles nothing.
    private static func batchStop(for error: any Error) -> Stop {
        guard !Task.isCancelled, let error = error as? APIError else { return .end }
        switch error {
        case .notFound, .http(405, _): return .unsupported
        default: return error.isTransient ? .retry : .end
        }
    }

    /// The session's result from a failed `/local`, or how the attempt stops when the failure
    /// says nothing about the session.
    private static func answer(to error: any Error) -> SessionAnswer {
        guard !Task.isCancelled, let error = error as? APIError else { return .stop(.end) }
        switch error {
        // The server reports a session it can't apply with a 500 and the reason.
        case .http(500, let message):
            return .result(.failure(message))
        case .http(let status, let message) where !error.isTransient && status != 405:
            return .result(.failure(message ?? "HTTP \(status)"))
        case .encoding(let message):
            return .result(.failure(message))
        default:
            return .stop(error.isTransient ? .retry : .end)
        }
    }

    private struct Payload {
        /// The stored `updatedAt`, which settlement compares exactly; the body carries it rounded.
        var updatedAt: Date
        var body: LocalPlaybackSessionPayload
    }

    /// What one request, or one round of `/local` requests, settles.
    private struct Attempt {
        /// The `updatedAt` sent for each session to settle. One sent to `local-all` without a
        /// result settles as unanswered.
        var sent: [String: Date] = [:]
        var results: [String: SessionUploadResult] = [:]
        var stop: Stop?

        mutating func answer(_ id: String, sent updatedAt: Date, _ result: SessionUploadResult) {
            sent[id] = updatedAt
            results[id] = result
        }
    }

    private enum Stop {
        /// No answer; try again after a backoff.
        case retry
        /// The server has no `local-all`.
        case unsupported
        /// Stop until the next sync.
        case end
    }

    private enum SessionAnswer {
        case result(SessionUploadResult)
        case stop(Stop)
    }
}

extension PlaybackSession {
    /// The session a pending local session uploads as.
    fileprivate init(pending session: PendingLocalSessionDTO) {
        self.init(
            id: session.id, userId: session.userId, libraryItemId: session.key.libraryItemId,
            episodeId: session.key.episodeId, mediaType: session.mediaType, displayTitle: session.displayTitle,
            displayAuthor: session.displayAuthor, duration: session.duration,
            playMethod: PlayMethod(rawValue: session.playMethod), timeListening: session.timeListening,
            startTime: session.startTime, currentTime: session.currentTime,
            startedAt: Self.milliseconds(session.startedAt), updatedAt: Self.milliseconds(session.updatedAt))
    }

    private static func milliseconds(_ date: Date) -> Int? {
        Int(exactly: (date.timeIntervalSince1970 * 1000).rounded())
    }
}
