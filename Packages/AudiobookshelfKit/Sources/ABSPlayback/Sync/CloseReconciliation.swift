import ABSAPI
import ABSData
import Foundation
import os

private let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "CloseReconciliation")

/// Whether a `/close` the server answered 404 counted (ADR 0007, #382).
enum CloseReconciliation: Equatable {
    /// Its listening time counted: the close is dropped.
    case applied
    /// It never counted: its listening time is carried into the media's next session.
    case notApplied
    /// Nothing tells: its listening time is dropped and logged, so it never counts twice.
    case undecidable
}

extension ProgressSyncer {
    /// Failed lookups of a missing close's record after which its listening time is dropped.
    static let maxCloseLookups = 6
    /// After this long from its capture, a close's session is gone: the server's nightly sweep
    /// (00:30) ends a session with no update for 36 h, and a close is its session's last
    /// update, so the session ends within 60 h; 12 h more cover clock drift. The drain then
    /// reconciles the close instead of resending it, so admission can't keep it forever.
    static let closeSessionLifetime: TimeInterval = 72 * 3600

    /// A 404, which the server answers only before a close or `/sync` applies anything (the
    /// session isn't open) and for a lookup of a missing item.
    static func isNotFound(_ error: any Error) -> Bool {
        switch error as? APIError {
        case .notFound: true
        case .http(let status, _): status == 404
        default: false
        }
    }

    /// A 404'd close's outcome, from `page`: the first page of its media's stored sessions.
    ///
    /// The server saves a session's listening time with each report and keeps the record once
    /// the session ends. The close's `ackedTotal` is what the server acknowledged before it, and
    /// its `inFlightTotal` what a `/sync` still out then reported, which may or may not have
    /// applied; an earlier report whose answer was lost can only add to the record. So, within
    /// ``reconcileTolerance``, a record holding all of these and the close applied it. One at
    /// `ackedTotal`, or at `ackedTotal + inFlightTotal`, didn't, unless it also matches the close
    /// applied without the `/sync`; any other can't tell. (`inFlightTotal` is 0 whenever an
    /// earlier report's outcome is unknown too, unreconciled or its lookup failed: the second
    /// match would prove nothing then.)
    /// The server stores no record before the session has listening time: with nothing
    /// acknowledged and every record on the page, a missing one shows nothing applied, the
    /// `/sync` included.
    static func reconcileClose(_ close: PendingSessionCloseDTO, page: ListeningSessionsPage) -> CloseReconciliation {
        let tolerance = reconcileTolerance
        let (acked, inFlight) = (close.ackedTotal, close.inFlightTotal)
        guard let record = page.sessions.first(where: { $0.id == close.sessionID }) else {
            return page.total <= page.sessions.count && acked == 0 ? .notApplied : .undecidable
        }
        let total = record.timeListening
        if total >= acked + inFlight + close.timeListened - tolerance { return .applied }
        let matches = { (expected: Double) in abs(total - expected) <= tolerance }
        let notApplied = matches(acked) || matches(acked + inFlight)
        return notApplied && !matches(acked + close.timeListened) ? .notApplied : .undecidable
    }

    /// Settles a retained close whose resend the server answered 404, that admission skipped for
    /// a newer session or position, or whose session must have ended, by its session's stored
    /// record (``reconcileClose(_:page:)``). A lookup that fails keeps it: later drains look
    /// again after ``closeRetryDelay(afterAttempts:)``, resending nothing, and after
    /// ``maxCloseLookups`` failures it is undecidable. Offline, cancelled or
    /// once the syncer stopped, nothing changes. A lookup for a missing item (404) or one
    /// refused for good is undecidable.
    /// Returns `false` when the drain should stop.
    func reconcileMissingClose(_ close: PendingSessionCloseDTO) async -> Bool {
        let verdict: CloseReconciliation
        do {
            let page = try await service.listeningSessions(
                itemID: close.key.libraryItemId, episodeID: close.key.episodeId)
            verdict = Self.reconcileClose(close, page: page)
        } catch let error where Self.isPermanent(error) {
            logger.error("Looking up a closed session was refused: \(Self.caseName(error), privacy: .public)")
            verdict = .undecidable
        } catch {
            logger.error("Looking up a closed session failed: \(Self.caseName(error), privacy: .public)")
            // Offline or cancelled, nothing was learned. A stopped syncer saves nothing either: a
            // replacement scope's drain may have settled the close (and carried its time) since.
            let learnedNothing =
                isDetached || isTransportQuiesced || error is CancellationError || Self.isOffline(error)
            if close.failedLookups + 1 >= Self.maxCloseLookups, !learnedNothing {
                verdict = .undecidable
            } else {
                // Unless nothing was learned, the failure counts toward the bound.
                drainOutcome.failed = true
                return learnedNothing ? false : await keepUnreconciledClose(close)
            }
        }
        // A detached syncer's close waits for the next scope's drain.
        guard !isDetached, !isTransportQuiesced else { return false }
        guard await settleMissingClose(close, verdict, stored: true) else {
            drainOutcome.failed = true
            return false
        }
        return true
    }

    /// Removes a 404'd close (when `stored`), then carries its listening time to the media's
    /// next loaded session if it never applied, or logs it as dropped if that's undecidable.
    /// Returns `false` when the removal failed: the close stays, for a drain to settle.
    func settleMissingClose(_ close: PendingSessionCloseDTO, _ verdict: CloseReconciliation, stored: Bool) async
        -> Bool
    {
        if stored {
            do {
                try await store.deleteSessionClose(
                    serverConnectionID: close.key.serverConnectionID, sessionID: close.sessionID)
            } catch {
                logger.error("Removing a missing session's close failed: \(Self.caseName(error), privacy: .public)")
                return false
            }
        }
        switch verdict {
        case .applied:
            logger.info("A closed session's stored record already counts its close")
        case .notApplied where isDetached || isTransportQuiesced:
            Self.logDroppedClose(close.timeListened, reason: "it never counted and the syncer stopped")
        case .notApplied:
            closeQueue.carry(close.timeListened, for: close.key)
            creditCarriedListening()
        case .undecidable:
            Self.logDroppedClose(close.timeListened, reason: "its session's stored record can't tell if it counted")
        }
        return true
    }

    /// Keeps a close whose lookup failed, to look again later; the failure counts as an attempt,
    /// so lookups back off as resends do. Returns `false` when it couldn't be saved.
    private func keepUnreconciledClose(_ close: PendingSessionCloseDTO) async -> Bool {
        var kept = close
        kept.failedLookups += 1
        kept.attempts += 1
        kept.lastAttemptAt = clock.now()
        do {
            try await store.saveSessionClose(kept)
            return true
        } catch {
            logger.error("Saving a close to look up again failed: \(Self.caseName(error), privacy: .public)")
            return false
        }
    }
}
