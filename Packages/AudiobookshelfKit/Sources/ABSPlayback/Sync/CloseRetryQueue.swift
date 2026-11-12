import ABSAPI
import ABSCore
import ABSData
import Foundation
import os

private let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "CloseRetryQueue")

/// The final `/close`s the server didn't acknowledge, kept in `LocalProgressStore` to retry (#382).
///
/// The coordinator makes one attempt. A close carrying listening time is stored while that
/// attempt is out, so a relaunch still finds it, and settled by its result:
/// - acknowledged: removed;
/// - suppressed (the account ended), or rejected for good (400, 404, 410, 422): removed, and its
///   listening time logged as dropped. TODO(#382): on 404, decide from the item's listening
///   sessions instead (ADR 0007).
/// - any other failure: kept. One that may have reached the server (a timeout, a lost
///   response, 5xx) isn't resent before ``ProgressSyncer/reconcileDelay``, so the original has
///   either applied (the server then answers the resend with 404, because a close removes the
///   session) or never will.
///
/// The drain's ``ProgressSyncer/retryRetainedCloses()`` resends each close that is due, oldest
/// first, once ``ProgressSyncer/admitDeferredReport(sessionID:key:currentTime:editedAt:)``
/// admits it; a skip for a newer session or position removes it.
@MainActor
final class CloseRetryQueue {
    /// Sessions whose coordinator `/close` hasn't settled yet: the drain leaves them alone.
    fileprivate(set) var capturing: Set<String> = []
    fileprivate var captures: [UUID: Task<Void, Never>] = [:]
    /// Test seam: every admission verdict, in order.
    fileprivate(set) var verdicts: [(sessionID: String, verdict: DeferredReportAdmission)] = []

    /// Waits until every captured close settled (tests). A held `/close` holds this too.
    func waitForCaptures() async {
        while let (id, task) = captures.first {
            await task.value
            captures[id] = nil
        }
    }
}

extension ProgressSyncer {
    /// After a close with listening time: stores it once its position committed, while the
    /// coordinator's attempt is out, then settles it by that attempt's result. The store
    /// keeps it even if this syncer is detached meanwhile (an account switch lets the close go on).
    func retainClose(_ handoff: PlaybackCloseHandoff, for closing: ClosingSession, token: PlaybackPositionToken?) {
        guard handoff.report.timeListened > 0, closing.key.serverConnectionID == service.serverConnectionID
        else { return }
        let queue = closeQueue
        let store = store
        let clock = clock
        let report = handoff.report
        let id = UUID()
        queue.capturing.insert(closing.sessionID)
        queue.captures[id] = Task { [weak self] in
            defer {
                queue.capturing.remove(closing.sessionID)
                queue.captures[id] = nil
            }
            // A failed receipt means the position never committed: there is nothing to admit.
            var editedAt: Date?
            if (try? await handoff.position.wait()) != nil, let token {
                editedAt = await store.committedPlaybackEdit(token, for: closing.key)
            }
            let close = PendingSessionCloseDTO(
                key: closing.key, sessionID: closing.sessionID, currentTime: report.currentTime,
                timeListened: report.timeListened, duration: report.duration, positionEditedAt: editedAt,
                capturedAt: clock.now())
            var stored = false
            if handoff.transport.result == nil, editedAt != nil {
                // The attempt may reach the server: a relaunch waits before resending it.
                var inFlight = close
                inFlight.lastAttemptAt = clock.now()
                do {
                    try await store.saveSessionClose(inFlight)
                    stored = true
                } catch {
                    logger.error("Saving a close to retry failed: \(Self.caseName(error), privacy: .public)")
                }
            }
            let result: Result<Bool, any Error>
            do { result = .success(try await handoff.transport.wait()) } catch { result = .failure(error) }
            if case .failure(let error) = result, !Self.isPermanent(error), editedAt == nil {
                // Admission could never send it (and it wasn't stored).
                Self.logDroppedClose(close.timeListened, reason: "its position never committed or was superseded")
                return
            }
            let settlement = await Self.settleClose(
                close, after: result, store: store, now: clock.now(), stored: stored)
            if settlement == .kept, let self, !self.isDetached, !self.isTransportQuiesced {
                self.scheduleDrainRetry()
            }
        }
    }

    /// The drain's close step: resends each retained close that is due and admitted, settling
    /// it by the result. Returns `false` when the drain should stop.
    func retryRetainedCloses() async -> Bool {
        let closes: [PendingSessionCloseDTO]
        do {
            closes = try await store.sessionCloses(for: service.serverConnectionID)
        } catch {
            logger.error("Reading closes to retry failed: \(Self.caseName(error), privacy: .public)")
            drainOutcome.failed = true
            return false
        }
        for close in closes where !closeQueue.capturing.contains(close.sessionID) {
            await waitForPendingWrites()
            guard !isDetached, !isTransportQuiesced, pendingPositions.isEmpty else { return false }
            if let last = close.lastAttemptAt, clock.now() < last + closeRetryDelay(afterAttempts: close.attempts) {
                // Not yet: the drain backs off and comes back.
                drainOutcome.failed = true
                continue
            }
            let verdict = await admitDeferredReport(
                sessionID: close.sessionID, key: close.key, currentTime: close.currentTime,
                editedAt: close.positionEditedAt)
            closeQueue.verdicts.append((close.sessionID, verdict))
            switch verdict {
            case .send:
                break
            case .skip(.quiesced):
                return false
            case .skip(.lookupFailed):
                drainOutcome.failed = true
                return false
            case .skip(let reason):
                // TODO(#383): carry the skipped listening time.
                Self.logDroppedClose(close.timeListened, reason: "admission skipped it (\(reason))")
                guard await deleteRetainedClose(close) else { return false }
                continue
            }
            guard
                let report = PlaybackSyncReport(
                    currentTime: close.currentTime, timeListened: close.timeListened, duration: close.duration)
            else {
                guard await deleteRetainedClose(close) else { return false }
                continue
            }
            let result: Result<Bool, any Error>
            do {
                try await service.closeSession(id: close.sessionID, report: report)
                result = .success(true)
            } catch {
                result = .failure(error)
            }
            switch await Self.settleClose(close, after: result, store: store, now: clock.now()) {
            case .finished:
                continue
            case .kept:
                drainOutcome.failed = true
                if case .failure(let error) = result, Self.isOffline(error) { return false }
            case .storeFailed:
                drainOutcome.failed = true
                return false
            }
        }
        return true
    }

    /// No resend before ``reconcileDelay`` after an attempt that may have reached the server,
    /// backed off like `/sync` after repeated failures.
    func closeRetryDelay(afterAttempts attempts: Int) -> TimeInterval {
        max(reconcileDelay, Self.syncBackoff(afterFailures: attempts))
    }

    enum CloseSettlement: Equatable {
        /// Acknowledged, or dropped for good.
        case finished
        /// Kept to retry.
        case kept
        /// The store couldn't save the result; the close stays as it was.
        case storeFailed
    }

    /// Removes an acknowledged or moot close and keeps one worth retrying, one attempt more.
    /// Only an attempt that may have reached the server moves `lastAttemptAt`.
    static func settleClose(
        _ close: PendingSessionCloseDTO, after result: Result<Bool, any Error>, store: LocalProgressStore,
        now: Date, stored: Bool = true
    ) async -> CloseSettlement {
        switch result {
        case .success(true):
            break
        case .success(false):
            logDroppedClose(close.timeListened, reason: "the account ended")
        case .failure(let error) where isPermanent(error):
            // TODO(#382): on 404, decide from the item's listening sessions (ADR 0007).
            logDroppedClose(close.timeListened, reason: "the server answered \(caseName(error))")
        case .failure(let error):
            var kept = close
            kept.attempts += 1
            if !neverReachedServer(error), !wasTurnedAway(error) { kept.lastAttemptAt = now }
            do {
                try await store.saveSessionClose(kept)
                return .kept
            } catch {
                logger.error("Saving a close to retry failed: \(caseName(error), privacy: .public)")
                return .storeFailed
            }
        }
        guard stored else { return .finished }
        do {
            try await store.deleteSessionClose(
                serverConnectionID: close.key.serverConnectionID, sessionID: close.sessionID)
            return .finished
        } catch {
            logger.error("Removing a settled close failed: \(caseName(error), privacy: .public)")
            return .storeFailed
        }
    }

    private func deleteRetainedClose(_ close: PendingSessionCloseDTO) async -> Bool {
        do {
            try await store.deleteSessionClose(
                serverConnectionID: close.key.serverConnectionID, sessionID: close.sessionID)
            return true
        } catch {
            logger.error("Removing a skipped close failed: \(Self.caseName(error), privacy: .public)")
            drainOutcome.failed = true
            return false
        }
    }

    static func logDroppedClose(_ listened: TimeInterval, reason: String) {
        logger.info(
            "Dropped \(listened, privacy: .public) s of listening time from a session's close: \(reason, privacy: .public)"
        )
    }
}
