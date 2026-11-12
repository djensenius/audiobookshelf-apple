import ABSCore
import ABSData
import Foundation
import os

private let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "DeferredReportAdmission")

/// Whether a deferred report (a retried `/close`) may still go out (#195 step 4, #382).
enum DeferredReportAdmission: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// The syncer is detached or its transport quiesced (the account ended).
        case quiesced
        /// Another session for the same media is current: its reports are newer.
        case newerSessionForMedia
        /// The server's progress couldn't be read and merged (offline, a failed lookup or store
        /// read, a reply the merge didn't take, a position saved or still being saved since the
        /// lookup, or a stored change to the row since its position was read): never send blind.
        case lookupFailed
        /// The stored position is no longer the report's own: a later local edit, another
        /// device's newer progress merged over it, or a position that never committed.
        case positionSuperseded
        /// The stored close is no longer the one the drain read: a capture settled it meanwhile,
        /// perhaps a retired playback scope's over the same store. What it saved stands.
        case closeChanged
    }

    case send
    case skip(Reason)
}

/// The state ``ProgressSyncer/deferredReportSkip(sessionID:key:since:)`` compares after each
/// suspension: the syncer's position revision and the store's change stamp for the key.
struct DeferredReportMark: Equatable {
    fileprivate let positionRevision: UInt64
    fileprivate let rowChange: UInt64
}

extension ProgressSyncer {
    /// The admission rule for a deferred report, checked in order before every resend:
    /// 1. detached or quiesced: skip;
    /// 2. a different session for the same media is current: skip;
    /// 3. read the server's progress through ``fetchProgress(for:attempted:attemptedKeys:confirmationOnly:)``
    ///    so the ADR 0003 merge decides; a failed lookup (offline included) skips;
    /// 4. the stored audio is no longer the report's own position: skip;
    /// 5. a reply the merge didn't take (step 3) decided nothing: skip;
    /// 6. otherwise send.
    ///
    /// Steps 1 and 2, that no position was queued since the lookup and that the store didn't
    /// change the row since (a reset or discard, say), are checked again after each suspension
    /// (``deferredReportSkip(sessionID:key:since:)``).
    ///
    /// The report's position is identified by the audio edit time it committed with
    /// (`editedAt`), not by its `PlaybackPositionToken`, which doesn't survive a relaunch. A
    /// skip never loses the position: its row stays dirty and the drain PATCHes it. The skipped
    /// report's listening time is #383's.
    func admitDeferredReport(
        sessionID: String, key: MediaKey, currentTime: Double, editedAt: Date?
    ) async -> DeferredReportAdmission {
        guard !isDetached, !isTransportQuiesced else { return .skip(.quiesced) }
        if hasNewerSession(than: sessionID, for: key) { return .skip(.newerSessionForMedia) }
        // A position still being saved commits first, so step 4 sees it.
        await waitForPendingWrites()
        var attempted: [MediaKey: UUID] = [:]
        var attemptedKeys: Set<MediaKey> = []
        let merged: Bool
        do {
            merged = try await fetchProgress(for: key, attempted: &attempted, attemptedKeys: &attemptedKeys)
        } catch {
            logger.info("A deferred report's progress lookup failed: \(Self.caseName(error), privacy: .public)")
            return .skip(.lookupFailed)
        }
        // A session may have started while the lookup was in flight. A position queued meanwhile
        // kept the merge from running (`fetchProgress` checks it), so there is nothing to compare.
        // The mark is taken before the position read, so any change after that read moves it.
        let mark = deferredReportMark(for: key)
        if let reason = deferredReportSkip(sessionID: sessionID, key: key, since: mark) { return .skip(reason) }
        guard let editedAt else { return .skip(.positionSuperseded) }
        let isLatest: Bool
        do {
            isLatest = try await store.isLatestPlaybackPosition(currentTime: currentTime, editedAt: editedAt, for: key)
        } catch {
            logger.error("Reading a deferred report's position failed: \(Self.caseName(error), privacy: .public)")
            return .skip(.lookupFailed)
        }
        await closeQueue.reached?(.positionRead)
        // The read suspended too: check again, with nothing after this before the caller acts.
        if let reason = deferredReportSkip(sessionID: sessionID, key: key, since: mark) { return .skip(reason) }
        guard isLatest else { return .skip(.positionSuperseded) }
        // A reply that wasn't merged (another item's, undated, or older than the stored server
        // progress) decided nothing: never send blind.
        return merged ? .send : .skip(.lookupFailed)
    }

    /// Steps 1 and 2 of the rule, a position queued since `mark`, and a stored change to the row
    /// since `mark` (any edit, merge or deletion, through the store's own stamp): checked again
    /// after each suspension, so the verdict holds when the caller acts on it without suspending.
    func deferredReportSkip(
        sessionID: String, key: MediaKey, since mark: DeferredReportMark
    ) -> DeferredReportAdmission.Reason? {
        if isDetached || isTransportQuiesced { return .quiesced }
        if hasNewerSession(than: sessionID, for: key) { return .newerSessionForMedia }
        guard pendingPositions.isEmpty, deferredReportMark(for: key) == mark else { return .lookupFailed }
        return nil
    }

    /// Where admission's re-checks start from: the syncer's position revision and the store's
    /// change stamp for `key`, both read without suspending.
    func deferredReportMark(for key: MediaKey) -> DeferredReportMark {
        DeferredReportMark(positionRevision: positionRevision, rowChange: store.rowChangeStamp(for: key))
    }

    private func hasNewerSession(than sessionID: String, for key: MediaKey) -> Bool {
        guard let current else { return false }
        return current.key == key && current.sessionID != sessionID
    }
}
