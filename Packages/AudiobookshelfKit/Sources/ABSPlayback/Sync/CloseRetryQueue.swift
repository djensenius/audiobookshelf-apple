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
/// - 404: the server no longer had the session, so nothing applied: removed, and its listening
///   time carried into the media's next session (``CloseRetryQueue/carried``, ADR 0007);
/// - suppressed (the account ended), or rejected for good (400, 410, 422): removed, and its
///   listening time logged as dropped;
/// - any other failure: kept. One that may have reached the server (a timeout, a lost
///   response, 5xx) isn't resent before ``ProgressSyncer/reconcileDelay``, so the original has
///   either applied (the server then answers the resend with 404, because a close removes the
///   session) or never will.
///
/// The drain's ``ProgressSyncer/retryRetainedCloses()`` resends each close that is due, oldest
/// first, once ``ProgressSyncer/admitDeferredReport(sessionID:key:currentTime:editedAt:)``
/// admits it; a skip for a newer session or position removes it. A resend answered 404 is
/// decided from the session's stored record (``ProgressSyncer/reconcileMissingClose(_:)``).
@MainActor
final class CloseRetryQueue {
    /// Sessions whose coordinator `/close` hasn't settled yet: the drain leaves them alone.
    fileprivate(set) var capturing: Set<String> = []
    /// The sessions captured during the drain's close pass: those under way when it began and
    /// those begun since. Drains run one at a time, so one pass owns it; `nil` outside a pass.
    fileprivate(set) var passCaptures: Set<String>?
    fileprivate var captures: [UUID: Task<Void, Never>] = [:]
    /// Test seam: hears each admission verdict, in order. Nothing keeps them otherwise.
    var verdictGiven: (@MainActor (_ sessionID: String, _ verdict: DeferredReportAdmission) -> Void)?
    /// Captured closes kept to retry that the store couldn't save, their first save included:
    /// only this holds them, so each drain saves them first. At most ``unsavedLimit``, the oldest
    /// dropped first; dropped on detach, as no drain follows.
    fileprivate(set) var unsaved: [PendingSessionCloseDTO] = []
    static let unsavedLimit = 16
    /// Listening time of closes the server never applied, by media, for that media's next loaded
    /// session to report (``ProgressSyncer/creditCarriedListening()``). At most ``unsavedLimit``
    /// media, the oldest dropped first. Only memory holds it: dropped on detach, and lost on a
    /// relaunch, which undercounts but never counts twice.
    fileprivate(set) var carried: [(key: MediaKey, seconds: TimeInterval)] = []

    /// The store calls after which state may have moved on (tests).
    enum Step: Sendable {
        /// Admission read the stored position; its checks run again next.
        case positionRead
        /// A resend's attempt time was saved; admission's checks run again next.
        case attemptSaved
        /// A captured close was saved while the coordinator's attempt is out.
        case captureSaved
        /// The coordinator's attempt settled; the capture saves its result next.
        case transportSettled
        /// A drain's close pass noted the sessions being captured; it reads the queue next.
        case passStarted
    }

    /// Test seam: runs after each ``Step``.
    var reached: (@MainActor (Step) async -> Void)?

    /// Waits until every captured close settled (tests). A held `/close` holds this too.
    func waitForCaptures() async {
        while let (id, task) = captures.first {
            await task.value
            captures[id] = nil
        }
    }

    /// Whether the drain's close pass leaves a session's close alone: its capture was under way
    /// when the pass began, began since, or is under way now.
    func passLeavesAlone(_ sessionID: String) -> Bool {
        capturing.contains(sessionID) || passCaptures?.contains(sessionID) == true
    }

    /// Holds a close the store couldn't save until a drain saves it.
    func holdUnsaved(_ close: PendingSessionCloseDTO) {
        unsaved.append(close)
        while unsaved.count > Self.unsavedLimit {
            ProgressSyncer.logDroppedClose(unsaved.removeFirst().timeListened, reason: "too many couldn't be saved")
        }
    }

    /// Drops the unsaved closes and the carried listening time, which no drain or session will
    /// report once the syncer is detached.
    func dropUnsaved() {
        for close in unsaved {
            ProgressSyncer.logDroppedClose(close.timeListened, reason: "it was never saved and the syncer detached")
        }
        unsaved = []
        for held in carried {
            ProgressSyncer.logDroppedClose(held.seconds, reason: "it was carried and the syncer detached")
        }
        carried = []
    }

    /// Holds `seconds` for `key`'s next loaded session.
    func carry(_ seconds: TimeInterval, for key: MediaKey) {
        if let index = carried.firstIndex(where: { $0.key == key }) {
            carried[index].seconds += seconds
            return
        }
        carried.append((key, seconds))
        while carried.count > Self.unsavedLimit {
            ProgressSyncer.logDroppedClose(carried.removeFirst().seconds, reason: "too many media had time carried")
        }
    }

    /// Takes the time carried for `key`.
    func takeCarried(for key: MediaKey) -> TimeInterval? {
        carried.firstIndex { $0.key == key }.map { carried.remove(at: $0).seconds }
    }
}

extension ProgressSyncer {
    /// After a close with listening time: stores it once its position committed, while the
    /// coordinator's attempt is out, then settles it by that attempt's result. The store
    /// keeps it even if this syncer is detached meanwhile (an account switch lets the close go on).
    /// One kept to retry that was never saved, its settlement's save included, waits in
    /// ``CloseRetryQueue/unsaved`` for the next drain to save it. `ackedTotal` is the session's
    /// listening time the server acknowledged, and `inFlightTotal` that of its `/sync` still out,
    /// for a later 404's lookup.
    func retainClose(
        _ handoff: PlaybackCloseHandoff, for closing: ClosingSession, ackedTotal: TimeInterval,
        inFlightTotal: TimeInterval, token: PlaybackPositionToken?
    ) {
        guard handoff.report.timeListened > 0, closing.key.serverConnectionID == service.serverConnectionID
        else { return }
        let queue = closeQueue
        let store = store
        let clock = clock
        let report = handoff.report
        let id = UUID()
        queue.capturing.insert(closing.sessionID)
        queue.passCaptures?.insert(closing.sessionID)
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
                capturedAt: clock.now(), ackedTotal: ackedTotal, inFlightTotal: inFlightTotal)
            var stored = false
            if handoff.transport.result == nil, editedAt != nil {
                // The attempt may reach the server: a relaunch waits before resending it.
                var inFlight = close
                inFlight.lastAttemptAt = clock.now()
                do {
                    try await store.saveSessionClose(inFlight)
                    stored = true
                    await queue.reached?(.captureSaved)
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
            await queue.reached?(.transportSettled)
            let now = clock.now()
            let settlement: CloseSettlement
            if case .failure(let error) = result, Self.isNotFound(error), let self, !self.isDetached,
                !self.isTransportQuiesced
            {
                // The server no longer had the session when the attempt arrived, so nothing
                // applied (ADR 0007): its listening time goes to the media's next session.
                settlement =
                    await self.settleMissingClose(close, .notApplied, stored: stored) ? .finished : .storeFailed
            } else {
                settlement = await Self.settleClose(close, after: result, store: store, now: now, stored: stored)
            }
            // Kept to retry but never saved (the attempt failed before it could be, or its save
            // failed too): nothing but memory holds it now.
            var unsaved: PendingSessionCloseDTO?
            if settlement == .storeFailed, !stored, case .failure(let error) = result {
                unsaved = Self.keptClose(close, after: error, now: now)
            }
            // A close kept to retry, or one whose settlement couldn't be saved, waits for a drain.
            // A drain running now would end as completed and cancel that retry: mark it failed.
            if settlement != .finished, let self, !self.isDetached, !self.isTransportQuiesced {
                if let unsaved { queue.holdUnsaved(unsaved) }
                self.drainOutcome.failed = true
                self.scheduleDrainRetry()
            } else if let unsaved {
                Self.logDroppedClose(unsaved.timeListened, reason: "it couldn't be saved to retry")
            }
        }
    }

    /// Saves the closes the capture couldn't (``CloseRetryQueue/unsaved``), first in each drain:
    /// it needs only the store, and a relaunch would lose them. If a save fails again, the rest
    /// wait for the next drain, which this one's failure schedules.
    func saveUnsavedCloses() async {
        while let close = closeQueue.unsaved.first {
            do {
                try await store.saveSessionClose(close)
            } catch {
                logger.error("Saving an unsaved close failed: \(Self.caseName(error), privacy: .public)")
                drainOutcome.failed = true
                return
            }
            if let index = closeQueue.unsaved.firstIndex(of: close) { closeQueue.unsaved.remove(at: index) }
        }
    }

    /// The drain's close step: resends each retained close that is due and admitted, settling
    /// it by the result. Returns `false` when the drain should stop.
    func retryRetainedCloses() async -> Bool {
        // A close being captured when the queue is read, or whose capture begins during this
        // pass, may settle while the pass is suspended on an earlier one, so the copy read here
        // is stale: the whole pass leaves it alone. A settlement that keeps the close schedules
        // another drain.
        assert(closeQueue.passCaptures == nil, "Drains run one at a time, so close passes never overlap")
        closeQueue.passCaptures = closeQueue.capturing
        defer { closeQueue.passCaptures = nil }
        await closeQueue.reached?(.passStarted)
        let closes: [PendingSessionCloseDTO]
        do {
            closes = try await store.sessionCloses(for: service.serverConnectionID)
        } catch {
            logger.error("Reading closes to retry failed: \(Self.caseName(error), privacy: .public)")
            drainOutcome.failed = true
            return false
        }
        for close in closes where !closeQueue.passLeavesAlone(close.sessionID) {
            await waitForPendingWrites()
            guard !isDetached, !isTransportQuiesced, pendingPositions.isEmpty else { return false }
            if let last = close.lastAttemptAt, clock.now() < last + closeRetryDelay(afterAttempts: close.attempts) {
                // Not yet: the drain backs off and comes back.
                drainOutcome.failed = true
                continue
            }
            if close.failedLookups > 0 || clock.now() >= close.capturedAt + Self.closeSessionLifetime {
                // The server answered 404 and the lookup failed, or the session must have ended:
                // its stored record decides, and nothing is resent (admission can't hold it).
                guard await reconcileMissingClose(close) else { return false }
                continue
            }
            var verdict = await admitDeferredReport(
                sessionID: close.sessionID, key: close.key, currentTime: close.currentTime,
                editedAt: close.positionEditedAt)
            if verdict == .send {
                guard let checked = await recordCloseAttempt(close) else {
                    drainOutcome.failed = true
                    return false
                }
                verdict = checked
            }
            closeQueue.verdictGiven?(close.sessionID, verdict)
            switch verdict {
            case .send:
                break
            case .skip(.quiesced):
                return false
            case .skip(.lookupFailed):
                drainOutcome.failed = true
                return false
            case .skip(.closeChanged):
                // Its settlement may have kept it with no drain to come (a retired scope's):
                // the next drain reads it as saved.
                drainOutcome.failed = true
                continue
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
            if case .failure(let error) = result, Self.isNotFound(error) {
                // The session is gone: its stored record tells whether the close counted.
                guard await reconcileMissingClose(close) else { return false }
                continue
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

    /// Saves a resend's attempt time before it goes out, as the coordinator's attempt is saved,
    /// so a relaunch while it is out waits ``reconcileDelay`` for it. The save is a claim: it
    /// happens only if the stored close is still the one the pass read, so a close that a
    /// capture settled meanwhile (another scope's included, which ``CloseRetryQueue/capturing``
    /// doesn't see) is neither recreated nor resent early. The save suspends, so admission's
    /// checks run again after it, with nothing after them before the send; the mark
    /// is taken in the same turn as admission's last check, so a reset or discard of the row
    /// meanwhile skips it. Returns the verdict that stands, or `nil` when the save failed and
    /// nothing may be sent. A skip after the save leaves that attempt time, which can only delay
    /// the close's next resend.
    private func recordCloseAttempt(_ close: PendingSessionCloseDTO) async -> DeferredReportAdmission? {
        let mark = deferredReportMark(for: close.key)
        do {
            guard try await store.claimSessionCloseAttempt(close, at: clock.now()) else { return .skip(.closeChanged) }
        } catch {
            logger.error("Saving a close's attempt failed: \(Self.caseName(error), privacy: .public)")
            return nil
        }
        await closeQueue.reached?(.attemptSaved)
        return deferredReportSkip(sessionID: close.sessionID, key: close.key, since: mark).map { .skip($0) }
            ?? .send
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
        /// The store couldn't save the result; the close stays as it was (in memory, for a
        /// capture's close never saved: ``CloseRetryQueue/unsaved``).
        case storeFailed
    }

    /// Removes an acknowledged or moot close and keeps one worth retrying (``keptClose(_:after:now:)``).
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
            // A 404 reaches here only for a capture whose syncer detached: nothing would report
            // its time (ADR 0007).
            logDroppedClose(close.timeListened, reason: "the server answered \(caseName(error))")
        case .failure(let error):
            do {
                try await store.saveSessionClose(keptClose(close, after: error, now: now))
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

    /// The close kept to retry after `error`: one attempt more. Only an attempt that may have
    /// reached the server moves `lastAttemptAt`.
    static func keptClose(_ close: PendingSessionCloseDTO, after error: any Error, now: Date) -> PendingSessionCloseDTO
    {
        var kept = close
        kept.attempts += 1
        if !neverReachedServer(error), !wasTurnedAway(error) { kept.lastAttemptAt = now }
        return kept
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
