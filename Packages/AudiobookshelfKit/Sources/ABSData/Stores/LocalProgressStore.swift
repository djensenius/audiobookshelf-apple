import ABSCore
import Foundation
import OSLog
import SwiftData
import Synchronization

/// Opaque in-process ordering for one writer/key's playback intent, reserved before suspension.
/// Successive playback scopes must share the same LocalProgressStore; tokens are not persisted.
public struct PlaybackPositionToken: Sendable, Equatable {
    fileprivate let writer: UUID
    fileprivate let key: MediaKey
    fileprivate let sequence: UInt64
}

public enum PlaybackPositionCommitResult: Sendable, Equatable {
    case committed
    /// A strictly newer token already committed. This call made no write.
    case supersededByCommittedPosition
}

public enum PlaybackPositionCommitError: Error, Sendable, Equatable {
    case wrongWriter
    case wrongKey
    /// The latest committed token is single-use, even when passed the same audio again.
    case tokenAlreadyCommitted
}

/// A point in `LocalProgressStore`'s edit history, captured when a progress fetch is issued or a
/// socket progress event is received. Server values are dropped for rows edited or settled since.
public struct ProgressGeneration: Sendable, Hashable, Comparable {
    let value: UInt64

    public static func < (lhs: ProgressGeneration, rhs: ProgressGeneration) -> Bool { lhs.value < rhs.value }
}

/// Pre-GET provenance for one start or active-session baseline GET (#279/#281). Retain only for
/// the lifetime of that request.
/// The issuing store alone can consume it; deletion invalidates it even if the key becomes
/// absent again. No persistent tombstone or per-key lifetime history is needed.
public final class PlaybackStartProgressCapture: Sendable {
    fileprivate let id = UUID()
    fileprivate let key: MediaKey
    fileprivate let generation: ProgressGeneration
    fileprivate let row: PersistentIdentifier?

    fileprivate init(key: MediaKey, generation: ProgressGeneration, row: PersistentIdentifier?) {
        self.key = key
        self.generation = generation
        self.row = row
    }
}

private struct WeakStartProgressCapture {
    weak var value: PlaybackStartProgressCapture?
}

/// A progress PATCH to send: one group (`values.groups`), with its values when it was taken.
public struct ProgressPatch: Sendable, Equatable {
    public var key: MediaKey
    public var values: ProgressSend
    /// Identifies this send; settling a patch that is no longer the row's send in flight does
    /// nothing.
    public let token: UUID
}

/// Identity of one durably prepared online report. Never pass this to PATCH completion.
public struct SessionAudioSend: Sendable, Equatable {
    public let key: MediaKey
    public let attemptID: UUID
}

public enum SessionAudioOutcome: Sendable, Equatable {
    case succeeded
    case notDelivered
    case ambiguous
}

/// Where server progress came from (``LocalProgressStore/applyServerProgress(_:capturedAt:source:)``).
public enum ServerProgressSource: Sendable, Equatable {
    /// `/api/me`, an expanded item or `/api/me/progress/:id`. A fetch that passes the generation
    /// check was issued after the row's last settlement, so it includes every acknowledged PATCH.
    case fetch
    /// A socket event (`user_updated`, `user_item_progress_updated`). It may have been emitted
    /// before an acknowledged PATCH was applied, as the PATCH's 200 has no body; a value equal to
    /// the acknowledged one doesn't prove otherwise.
    case socket
}

/// The server's per-session answer to `POST /api/session/local-all`.
public enum SessionUploadResult: Sendable, Equatable {
    case success
    case failure(String?)
}

/// The only writer of `LocalMediaProgress` and `PendingLocalSession` (ADR 0003).
///
/// Progress follows the ADR 0003 sync rules: local edits mark only the field groups they touch,
/// each PATCH carries one dirty group (audio, then finished, then ebook; #53), at most one PATCH
/// is in flight per row, and server progress is merged per group
/// (``applyServerProgress(_:capturedAt:source:)``) after dropping values captured before the row's last
/// local edit or PATCH settlement. Every write is saved through ``commit(_:)``, which rolls the
/// context back when it fails; in-memory bookkeeping changes only after a successful save.
@ModelActor public actor LocalProgressStore: StoreActor {
    private nonisolated let playbackWriterID = UUID()
    private nonisolated let playbackSequence = Mutex<UInt64>(0)
    /// One successful watermark per key, never pending reservations or a history of tokens.
    private var committedPlaybackPositions:
        [MediaKey: (sequence: UInt64, row: PersistentIdentifier, audio: ProgressSend.Audio)] = [:]
    /// Writer-owned settlement survives syncer retirement. A failed save retains this precise
    /// outcome; a process reopen instead retains the conservative prepared evidence on disk.
    private var sessionAudioSends:
        [UUID: (
            key: MediaKey, row: PersistentIdentifier, values: ProgressSend, outcome: SessionAudioOutcome?
        )] = [:]
    /// Pending sessions are discarded after this many counted upload failures.
    public static let maxUploadFailures = 5
    /// At most one failure per session is counted in this interval.
    public static let uploadFailureWindow: TimeInterval = 60 * 60
    /// This many consecutive uploads without a result for a session count as one failure.
    public static let missingResultsPerFailure = 3

    var pendingCommitFailure: (any Error)?
    /// Test seams: the next row lookup fails with this error; the number of row lookups made.
    private var pendingFetchFailure: (any Error)?
    private(set) var rowFetchCount = 0

    // In memory only: no fetch or PATCH outlives the process.
    private var generation: UInt64 = 0
    private var rowGenerations: [String: UInt64] = [:]
    /// Weak registrations are swept on every capture; storage is bounded by overlapping starts,
    /// not every media key ever seen. Abandoned/failed starts need no asynchronous cleanup task.
    private var startCaptures: [UUID: WeakStartProgressCapture] = [:]
    /// The generation after each row last merged server values: a fetch captured since was read
    /// after the server held them.
    private var mergedAt: [String: UInt64] = [:]
    /// The send in flight per row, with the row it was taken from: a row deleted meanwhile and
    /// recreated for the same key isn't the one the response settles.
    private var inFlight: [String: (token: UUID, groups: ProgressGroups, row: PersistentIdentifier)] = [:]
    /// Outcomes whose save failed while their send stays in flight (a rejection's cleanup, or a
    /// recreated row's shield). Kept here, not by the caller, so ``beginSend(for:now:)`` retries
    /// them even after that caller retired (#337).
    private var pendingOutcomes: [String: (patch: ProgressPatch, outcome: SendOutcome)] = [:]
    /// Rows acknowledged without a server time that wait for a fetch issued after the
    /// acknowledgement, with the latest socket value received meanwhile and its capture.
    /// Rows whose latest send was an ebook one: their next send goes back to audio or finished.
    private var ebookSentLast: Set<String> = []
    private var awaitingFetch:
        [String: (key: MediaKey, acknowledgement: UUID, latest: (server: ProgressBaseline, capturedAt: UInt64)?)] = [:]

    private static let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "persistence")

    // MARK: - Progress

    /// Rows whose PATCH was acknowledged without a server time: fetch each one
    /// (`GET /api/me/progress/:id`, capturing the generation first) and apply it with
    /// `source: .fetch`. Until then their socket values are held. Without the fetch a row keeps
    /// the acknowledged values, which the server holds unless it normalized them.
    public var needsConfirmationFetch: Set<MediaKey> {
        Set(awaitingFetch.values.map(\.key))
    }

    /// Captures the current generation; pass it to ``applyServerProgress(_:capturedAt:source:)``.
    public func captureGeneration() -> ProgressGeneration {
        ProgressGeneration(value: generation)
    }

    /// Coherent admission snapshot for a canonical GET. Only a committed, genuine PATCH ACK
    /// creates this identity; edits, failed/obsolete settlements and duplicate outcomes do not.
    public func captureProgressFetch(for key: MediaKey) -> (generation: ProgressGeneration, acknowledgement: UUID?) {
        (captureGeneration(), awaitingFetch[key.rawValue]?.acknowledgement)
    }

    /// Capture before a start or active-session baseline GET (#279/#281). A failed lookup is not
    /// evidence of absence.
    public func captureStartProgress(for key: MediaKey) throws -> PlaybackStartProgressCapture {
        startCaptures = startCaptures.filter { $0.value.value != nil }
        let row = try fetchRow(key)
        let capture = PlaybackStartProgressCapture(
            key: key, generation: captureGeneration(), row: row?.persistentModelID)
        startCaptures[capture.id] = WeakStartProgressCapture(value: capture)
        return capture
    }

    /// Narrow, one-shot canonical intake for a start or active-session baseline GET (#279/#281).
    /// Validation, provenance and mutation are atomic on this actor. Ordinary server intake still
    /// ignores unknown rows.
    @discardableResult
    public func applyStartProgress(_ progress: MediaProgress, captured: PlaybackStartProgressCapture) throws -> Bool {
        guard startCaptures[captured.id]?.value === captured else { return false }
        defer { startCaptures[captured.id] = nil }
        let key = captured.key
        guard progress.libraryItemId == key.libraryItemId,
            (progress.episodeId ?? "") == (key.episodeId ?? ""),
            let lastUpdate = progress.lastUpdate,
            !hasChanged(key, since: captured.generation)
        else { return false }
        let row = try fetchRow(key)
        guard row?.persistentModelID == captured.row else { return false }
        let server = ProgressBaseline(
            currentTime: progress.currentTime, progress: progress.progress, duration: progress.duration,
            isFinished: progress.isFinished,
            finishedAt: progress.finishedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
            ebookLocation: progress.ebookLocation, ebookProgress: progress.ebookProgress,
            lastUpdate: Date(timeIntervalSince1970: Double(lastUpdate) / 1000))
        if row != nil {
            return try applyServerProgress([key: server], capturedAt: captured.generation, source: .fetch).contains(key)
        }
        try commit {
            let row = LocalMediaProgress(
                key: key.rawValue, serverConnectionID: key.serverConnectionID,
                libraryItemId: key.libraryItemId, episodeId: key.episodeId,
                startedAt: progress.startedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                lastUpdate: server.lastUpdate)
            modelContext.insert(row)
            var state = ProgressSyncState(seed: server)
            // An issued report can outlive a deletion. Preserve its evidence, not a local edit.
            for owned in sessionAudioSends.values where owned.key == key {
                state.recordSessionAudio(owned.values)
            }
            state.write(to: row)
        }
        generation += 1
        mergedAt[key.rawValue] = generation
        return true
    }

    /// Tests an authoritative absent lookup without synthesizing a baseline or confirming a
    /// PATCH. Dated values must still go through `applyServerProgress` and its merge rules.
    public func hasChanged(_ key: MediaKey, since capturedAt: ProgressGeneration) -> Bool {
        (rowGenerations[key.rawValue] ?? 0) > capturedAt.value
    }

    /// Reserves order synchronously at intent capture, not when a delayed write reaches the actor.
    public nonisolated func reservePlaybackPosition(for key: MediaKey) -> PlaybackPositionToken {
        let sequence = playbackSequence.withLock {
            $0 += 1
            return $0
        }
        return PlaybackPositionToken(writer: playbackWriterID, key: key, sequence: sequence)
    }

    /// Atomically checks playback order, commits through `recordEdit`, and advances the successful
    /// watermark. No await separates those operations. Failed writes/reservations do not supersede
    /// anything. Repeating the latest committed token throws; older tokens return superseded
    /// without writing, irrespective of their payload. Generic `recordEdit` semantics are unchanged.
    public func recordPlaybackPosition(
        _ audio: ProgressEdit.Audio, for key: MediaKey, token: PlaybackPositionToken, now: Date
    ) throws -> PlaybackPositionCommitResult {
        guard token.writer == playbackWriterID else { throw PlaybackPositionCommitError.wrongWriter }
        guard token.key == key else { throw PlaybackPositionCommitError.wrongKey }
        if let committed = committedPlaybackPositions[key] {
            if token.sequence < committed.sequence { return .supersededByCommittedPosition }
            if token.sequence == committed.sequence { throw PlaybackPositionCommitError.tokenAlreadyCommitted }
        }
        try recordEdit(
            ProgressEdit(audio: audio), for: key, serverProgress: nil, localLibraryItemID: nil,
            now: now, playbackToken: token)
        return .committed
    }

    /// Records a local change, creating the row when needed.
    ///
    /// - Parameters:
    ///   - serverProgress: The server's progress for the media, when known; seeds a new row (all
    ///     fields and the baseline, nothing dirty) before the edit is applied. Ignored for an
    ///     existing row.
    ///   - localLibraryItemID: The downloaded item, if any; `nil` keeps the stored value.
    @discardableResult
    public func recordEdit(
        _ edit: ProgressEdit,
        for key: MediaKey,
        serverProgress: ProgressBaseline? = nil,
        localLibraryItemID: UUID? = nil,
        now: Date = .now
    ) throws -> LocalMediaProgressDTO {
        try recordEdit(
            edit, for: key, serverProgress: serverProgress, localLibraryItemID: localLibraryItemID,
            now: now, playbackToken: nil)
    }

    /// Records an ebook location turned at `now` and saved later, unless it was superseded
    /// meanwhile. The check and the write are one step on this actor. A turn is dropped when:
    /// - the server's ebook location changed to one dated at or after the turn: a merge in between
    ///   would have taken that location over the turn (the server wins ties), so saving the turn
    ///   now would mark it dirty against that value and PATCH over it;
    /// - the row holds an unsent ebook edit turned after it, for example by another reader of the
    ///   same media: the turn's date, taken when it was made, orders it before that edit.
    ///
    /// - Parameters:
    ///   - knownLocations: The server ebook locations the editor accounted for when the turn was
    ///     made: the row's ``LocalMediaProgressDTO/serverBaseline`` location as last read, and the
    ///     locations it saved since, whose acknowledgement moves the baseline too. `nil` when
    ///     unknown, which never drops the turn.
    ///   - serverProgress, localLibraryItemID: As for ``recordEdit(_:for:serverProgress:localLibraryItemID:now:)``.
    /// - Returns: The saved row, or `nil` when the turn was dropped: the row's baseline is dated
    ///   at or after `now` and holds a location not in `knownLocations`, or its unsent ebook edit
    ///   is dated after `now`.
    @discardableResult
    public func recordEbookTurn(
        _ ebook: ProgressEdit.Ebook,
        for key: MediaKey,
        knownLocations: [String?]?,
        serverProgress: ProgressBaseline? = nil,
        localLibraryItemID: UUID? = nil,
        now: Date
    ) throws -> LocalMediaProgressDTO? {
        if let row = try fetchRow(key) {
            let state = ProgressSyncState(row)
            if row.ebookDirty, let savedAt = state.savedAt(.ebook), savedAt > now { return nil }
            if let knownLocations, let baseline = state.serverBaseline, baseline.lastUpdate >= now,
                baseline.ebookLocationIsUnknown != true, !knownLocations.contains(baseline.ebookLocation)
            {
                return nil
            }
        }
        return try recordEdit(
            ProgressEdit(ebook: ebook), for: key, serverProgress: serverProgress,
            localLibraryItemID: localLibraryItemID, now: now, playbackToken: nil)
    }

    @discardableResult
    private func recordEdit(
        _ edit: ProgressEdit, for key: MediaKey, serverProgress: ProgressBaseline?,
        localLibraryItemID: UUID?, now: Date, playbackToken: PlaybackPositionToken?
    ) throws -> LocalMediaProgressDTO {
        let saved = try commit {
            let row: LocalMediaProgress
            var state: ProgressSyncState
            if let existing = try fetchRow(key) {
                row = existing
                state = ProgressSyncState(existing)
            } else {
                row = LocalMediaProgress(
                    key: key.rawValue,
                    serverConnectionID: key.serverConnectionID,
                    libraryItemId: key.libraryItemId,
                    episodeId: key.episodeId,
                    startedAt: now,
                    lastUpdate: now
                )
                modelContext.insert(row)
                state = serverProgress.map(ProgressSyncState.init(seed:)) ?? ProgressSyncState(lastUpdate: now)
                // Deleting/recreating the row does not stop an issued report. Preserve its
                // evidence in the same commit as the replacement's first edit, before settlement.
                for owned in sessionAudioSends.values where owned.key == key {
                    state.recordSessionAudio(owned.values)
                }
            }
            if let localLibraryItemID { row.localLibraryItemID = localLibraryItemID }
            state.apply(edit, now: now)
            state.write(to: row)
            return (LocalMediaProgressDTO(row), row)
        }
        if let playbackToken, let audio = saved.0.dirtyValues.audio {
            committedPlaybackPositions[key] = (playbackToken.sequence, saved.1.persistentModelID, audio)
        }
        advance(key)
        return saved.0
    }

    /// Uses the originating committed token and row, never the latest dirty group's values.
    /// A superseded/deleted/generically edited capture is safely deferred without a transport.
    public func prepareSessionAudio(
        for key: MediaKey, token: PlaybackPositionToken, audio: ProgressEdit.Audio, sessionID: String
    ) throws -> SessionAudioSend? {
        guard token.writer == playbackWriterID else { throw PlaybackPositionCommitError.wrongWriter }
        guard token.key == key else { throw PlaybackPositionCommitError.wrongKey }
        try retrySessionAudioSettlements(for: key.serverConnectionID)
        guard inFlight[key.rawValue] == nil, !sessionAudioSends.values.contains(where: { $0.key == key }),
            let committed = committedPlaybackPositions[key], committed.sequence == token.sequence,
            committed.audio.currentTime == audio.currentTime, committed.audio.duration == audio.duration,
            committed.audio.progress == audio.progress
        else { return nil }
        let attemptID = UUID()
        var send = ProgressSend(audio: committed.audio)
        send.sessionAudio = .init(attemptID: attemptID, sessionID: sessionID)
        let prepared = try commit {
            guard let row = try fetchRow(key), row.persistentModelID == committed.row,
                row.audioEditedAt == committed.audio.editedAt,
                row.currentTime == audio.currentTime, row.duration == audio.duration
            else { return false }
            var state = ProgressSyncState(row)
            state.recordSessionAudio(send)
            state.write(to: row)
            return true
        }
        guard prepared else { return nil }
        sessionAudioSends[attemptID] = (key, committed.row, send, nil)
        return SessionAudioSend(key: key, attemptID: attemptID)
    }

    /// Retains an exact local obligation before any lookup/save can fail. Success does not
    /// fabricate a baseline, server time, PATCH acknowledgement or listening-time result.
    public func settleSessionAudio(_ send: SessionAudioSend, outcome: SessionAudioOutcome) throws {
        guard let owned = sessionAudioSends[send.attemptID], owned.key == send.key else { return }
        if owned.outcome == nil { sessionAudioSends[send.attemptID]?.outcome = outcome }
        try settleSessionAudio(send.attemptID)
    }

    /// Retry owned outcomes even after the transport scope retired, before any fresh transport.
    public func retrySessionAudioSettlements(for connectionID: UUID) throws {
        let attempts = sessionAudioSends.filter { $0.value.key.serverConnectionID == connectionID }
        for (id, owned) in attempts where owned.outcome != nil {
            try settleSessionAudio(id)
        }
    }

    private func settleSessionAudio(_ id: UUID) throws {
        guard let owned = sessionAudioSends[id], let outcome = owned.outcome else { return }
        try commit {
            guard let row = try fetchRow(owned.key) else { return }
            var state = ProgressSyncState(row)
            switch outcome {
            case .notDelivered:
                // Never remove another attempt with equal values, including on a recreated row.
                state.rejectSessionAudio(id)
            case .succeeded, .ambiguous:
                var evidence = owned.values
                evidence.sessionAudio?.outcome = outcome == .succeeded ? .succeeded : .ambiguous
                state.recordSessionAudio(evidence)
            }
            state.write(to: row)
        }
        sessionAudioSends[id] = nil
        advance(owned.key)
    }

    /// Merges server progress (from `/api/me`, an expanded item, `/api/me/progress/:id` or a
    /// socket event) into existing rows; media without a row is skipped. Values for a row edited
    /// or settled since `capturedAt` are dropped, and groups carried by a PATCH in flight aren't
    /// merged, nor are values whose `lastUpdate` isn't later than the baseline's (another write in
    /// the same millisecond may predate it), except from a fetch captured after the row's last
    /// merge. Returns the keys whose rows were merged.
    ///
    /// A PATCH's 200 carries no server time, so after an acknowledgement a socket event may have
    /// been emitted before the PATCH was applied, with any `lastUpdate`. Until a fetch issued
    /// after the acknowledgement is applied (``needsConfirmationFetch``), socket values for the
    /// row aren't merged; the latest is kept and merged after that fetch only if its `lastUpdate`
    /// is strictly later than the fetch's (on a tie the fetch wins).
    @discardableResult
    public func applyServerProgress(
        _ updates: [MediaKey: ProgressBaseline],
        capturedAt: ProgressGeneration,
        source: ServerProgressSource
    ) throws -> Set<MediaKey> {
        var recorded: [String: ProgressBaseline] = [:]
        var confirmed: Set<String> = []
        let merged = try commit {
            var merged: Set<MediaKey> = []
            let rows = try fetchRows(of: Set(updates.keys.map(\.serverConnectionID)))
            for (key, server) in updates {
                let raw = key.rawValue
                guard let row = rows[raw] else { continue }
                if hasChanged(key, since: capturedAt) { continue }
                let takingTies = source == .fetch && capturedAt.value >= mergedAt[raw] ?? 0
                guard let awaiting = awaitingFetch[raw] else {
                    if merge(server, into: row, takingTies: takingTies) { merged.insert(key) }
                    continue
                }
                guard source == .fetch else {
                    recorded[raw] = server
                    continue
                }
                // Passing the generation check, the fetch was issued after the acknowledgement.
                confirmed.insert(raw)
                if merge(server, into: row, takingTies: takingTies) { merged.insert(key) }
                // Server times are milliseconds, so a pre-PATCH snapshot can tie the fetch; only a
                // strictly newer one can have been emitted after it.
                if let latest = awaiting.latest, rowGenerations[raw] ?? 0 <= latest.capturedAt,
                    latest.server.lastUpdate > server.lastUpdate,
                    merge(latest.server, into: row)
                {
                    merged.insert(key)
                }
            }
            return merged
        }
        for (raw, server) in recorded {
            awaitingFetch[raw]?.latest = (server, capturedAt.value)
        }
        for raw in confirmed {
            awaitingFetch[raw] = nil
        }
        if !merged.isEmpty {
            generation += 1
            for key in merged { mergedAt[key.rawValue] = generation }
        }
        return merged
    }

    /// Takes a snapshot of the row's next dirty group (audio, then finished, then ebook) for a
    /// PATCH and records it as unacknowledged. Returns `nil` when there is no row, nothing is
    /// dirty, or a PATCH for the row is already in flight. Settle every returned patch with
    /// ``completeSend(_:serverLastUpdate:)``, ``failSend(_:error:)`` or ``rejectSend(_:error:)``,
    /// then call this again for the next group. An outcome whose save failed with its send left
    /// in flight is saved first; if that fails again, this throws.
    public func beginSend(for key: MediaKey, now: Date = .now) throws -> ProgressPatch? {
        try retrySessionAudioSettlements(for: key.serverConnectionID)
        guard !sessionAudioSends.values.contains(where: { $0.key == key }) else { return nil }
        if let pending = pendingOutcomes[key.rawValue] {
            switch pending.outcome {
            case .completed(let serverLastUpdate): try completeSend(pending.patch, serverLastUpdate: serverLastUpdate)
            case .failed(let error): try failSend(pending.patch, error: error)
            case .rejected(let error): try rejectSend(pending.patch, error: error)
            }
        }
        guard inFlight[key.rawValue] == nil else { return nil }
        let taken: (ProgressSend, PersistentIdentifier)? = try commit {
            guard let row = try fetchRow(key) else { return nil }
            var state = ProgressSyncState(row)
            state.ebookSentLast = ebookSentLast.contains(key.rawValue)
            guard let send = state.beginSend() else { return nil }
            state.write(to: row)
            row.lastSyncAttemptAt = now
            return (send, row.persistentModelID)
        }
        guard let (send, rowID) = taken else { return nil }
        let patch = ProgressPatch(key: key, values: send, token: UUID())
        inFlight[key.rawValue] = (patch.token, send.groups, rowID)
        if send.groups == .ebook {
            ebookSentLast.insert(key.rawValue)
        } else {
            ebookSentLast.remove(key.rawValue)
        }
        return patch
    }

    /// The PATCH succeeded. `serverLastUpdate` is the response's `lastUpdate`, when it has one.
    /// Returns `false`, changing nothing, when `patch` is not the row's send in flight (a late or
    /// repeated response for a send already settled). A row deleted and recreated for the same
    /// key since ``beginSend(for:now:)`` isn't acknowledged, but its pending edits are shielded
    /// from the old PATCH's echo; if that can't be saved, the send stays in flight and this
    /// throws, so retry it. The store keeps the outcome: the next ``beginSend(for:now:)`` for
    /// the key retries it too, from any caller.
    @discardableResult
    public func completeSend(_ patch: ProgressPatch, serverLastUpdate: Date?) throws -> Bool {
        guard let flight = inFlight[patch.key.rawValue], flight.token == patch.token else { return false }
        defer { retainIfStillInFlight(patch, .completed(serverLastUpdate)) }
        let acknowledged = try settle(patch.key, sentFrom: flight.row) { row in
            var state = ProgressSyncState(row)
            state.acknowledge(patch.values, serverLastUpdate: serverLastUpdate)
            state.write(to: row)
            row.lastSyncError = nil
        }
        if acknowledged, serverLastUpdate == nil {
            awaitingFetch[patch.key.rawValue] = (patch.key, patch.token, nil)
        }
        return true
    }

    /// The PATCH failed or its response was lost. The send stays recorded as unacknowledged, and
    /// the next attempt sends the then-current values. Returns `false`, changing nothing, when
    /// `patch` is not the row's send in flight. Like ``completeSend(_:serverLastUpdate:)``, it
    /// throws without settling when a recreated row's shield can't be saved; retry it.
    ///
    /// Call this only once the PATCH's `URLSessionTask` has really completed (ADR 0007, #53). The
    /// token stops a late outcome from settling a newer send, but it can't stop an old request
    /// that is still running from reaching the server after a newer one; the sync coordinator
    /// must not start the next send while the previous task may still be delivered.
    @discardableResult
    public func failSend(_ patch: ProgressPatch, error: String?) throws -> Bool {
        guard let flight = inFlight[patch.key.rawValue], flight.token == patch.token else { return false }
        defer { retainIfStillInFlight(patch, .failed(error)) }
        try settle(patch.key, sentFrom: flight.row) { $0.lastSyncError = error }
        return true
    }

    /// The server rejected the PATCH for good (for example, the item is gone), so resending it
    /// can't succeed. Its groups stop being dirty unless edited since ``beginSend(for:now:)``,
    /// so the row no longer keeps the connection retained; a later edit sends again. The
    /// baseline is unchanged, and `error` is kept in `lastSyncError`. Returns `false`, changing
    /// nothing, when `patch` is not the row's send in flight. If the cleanup can't be saved, the
    /// send stays in flight, so the row isn't PATCHed again with the same values, and this
    /// throws. The store keeps the outcome: retry it, or the next ``beginSend(for:now:)`` for
    /// the key does, from any caller.
    @discardableResult
    public func rejectSend(_ patch: ProgressPatch, error: String) throws -> Bool {
        guard let flight = inFlight[patch.key.rawValue], flight.token == patch.token else { return false }
        defer { retainIfStillInFlight(patch, .rejected(error)) }
        try settle(patch.key, sentFrom: flight.row, retainingOnFailure: true) { row in
            var state = ProgressSyncState(row)
            state.reject(patch.values)
            state.write(to: row)
            row.lastSyncError = error
        }
        return true
    }

    private enum SendOutcome {
        case completed(Date?)
        case failed(String?)
        case rejected(String)
    }

    /// Keeps `outcome` for ``beginSend(for:now:)`` to retry while its send is still in flight.
    private func retainIfStillInFlight(_ patch: ProgressPatch, _ outcome: SendOutcome) {
        let key = patch.key.rawValue
        pendingOutcomes[key] = inFlight[key]?.token == patch.token ? (patch, outcome) : nil
    }

    public func progress(for key: MediaKey) throws -> LocalMediaProgressDTO? {
        try fetchRow(key).map(LocalMediaProgressDTO.init)
    }

    public func progress(localLibraryItemID: UUID) throws -> [LocalMediaProgressDTO] {
        try fetchRows(#Predicate { $0.localLibraryItemID == localLibraryItemID })
    }

    /// Rows with changes the server hasn't acknowledged, for one connection.
    public func pendingSync(for serverConnectionID: UUID) throws -> [LocalMediaProgressDTO] {
        try fetchRows(#Predicate { $0.needsServerSync && $0.serverConnectionID == serverConnectionID })
    }

    /// Links the row to a downloaded item, or unlinks it (`nil`) when the download is deleted.
    @discardableResult
    public func setLocalLibraryItemID(_ id: UUID?, for key: MediaKey) throws -> Bool {
        try commit {
            guard let row = try fetchRow(key) else { return false }
            row.localLibraryItemID = id
            return true
        }
    }

    @discardableResult
    public func deleteProgress(for key: MediaKey) throws -> Bool {
        let deleted = try commit {
            guard let row = try fetchRow(key) else { return false }
            modelContext.delete(row)
            return true
        }
        if deleted {
            invalidateStartCaptures(for: key.rawValue)
            rowGenerations[key.rawValue] = nil
            mergedAt[key.rawValue] = nil
            awaitingFetch[key.rawValue] = nil
            ebookSentLast.remove(key.rawValue)
        }
        return deleted
    }

    /// Deletes synced rows that don't belong to a download. Returns the number deleted.
    @discardableResult
    public func pruneSynced() throws -> Int {
        let predicate = #Predicate<LocalMediaProgress> { !$0.needsServerSync && $0.localLibraryItemID == nil }
        // Row by row: a batch delete bypasses the context, so a failed save couldn't roll it back.
        let keys = try commit {
            let rows = try modelContext.fetch(FetchDescriptor(predicate: predicate))
            for row in rows {
                modelContext.delete(row)
            }
            return rows.map(\.key)
        }
        for key in keys {
            invalidateStartCaptures(for: key)
            awaitingFetch[key] = nil
            mergedAt[key] = nil
            if inFlight[key] == nil { rowGenerations[key] = nil }
        }
        return keys.count
    }

    // MARK: - Pending sessions

    /// Inserts the session, or updates the one with the same `id` in place. The upload
    /// bookkeeping (`uploadAttempts`, `lastUploadError`) is never taken from `session`; only
    /// ``settleSessionUpload(sent:results:isFirstSync:now:)`` changes it.
    public func saveSession(_ session: PendingLocalSessionDTO) throws {
        try commit {
            if let existing = try fetchSession(id: session.id) {
                session.write(to: existing)
                return
            }
            let model = PendingLocalSession(
                id: session.id,
                serverConnectionID: session.key.serverConnectionID,
                userId: session.userId,
                libraryItemId: session.key.libraryItemId,
                mediaType: session.mediaType,
                displayTitle: session.displayTitle,
                duration: session.duration,
                startTime: session.startTime,
                currentTime: session.currentTime
            )
            session.write(to: model)
            modelContext.insert(model)
        }
    }

    public func session(id: String) throws -> PendingLocalSessionDTO? {
        try fetchSession(id: id).map(PendingLocalSessionDTO.init)
    }

    /// The connection's sessions waiting for upload, oldest first.
    public func pendingSessions(for serverConnectionID: UUID) throws -> [PendingLocalSessionDTO] {
        let descriptor = FetchDescriptor<PendingLocalSession>(
            predicate: #Predicate { $0.serverConnectionID == serverConnectionID },
            sortBy: [SortDescriptor(\.startedAt), SortDescriptor(\.id)]
        )
        return try modelContext.fetch(descriptor).map(PendingLocalSessionDTO.init)
    }

    @discardableResult
    public func deleteSession(id: String) throws -> Bool {
        try commit {
            guard let session = try fetchSession(id: id) else { return false }
            modelContext.delete(session)
            return true
        }
    }

    /// Applies the per-session results of a `local-all` upload; never the batch's HTTP status.
    ///
    /// - A success resets the session's upload bookkeeping. The session is deleted only when it
    ///   wasn't changed while the upload was in flight (its `updatedAt` still equals the one
    ///   sent) and isn't active (active ones too on the first sync after login).
    /// - A failure counts toward discarding the session, and ``missingResultsPerFailure``
    ///   consecutive uploads without a result count as one failure, but only when the session
    ///   wasn't changed during the upload (newer data may succeed) and no failure was counted in
    ///   the last ``uploadFailureWindow``. After ``maxUploadFailures`` counted failures the
    ///   session is discarded and logged. The latest error is stored in `lastUploadError` even
    ///   when the failure isn't counted.
    ///
    /// - Parameter sent: The `updatedAt` sent for each session, by id.
    /// - Returns: The ids of the deleted sessions.
    @discardableResult
    public func settleSessionUpload(
        sent: [String: Date],
        results: [String: SessionUploadResult],
        isFirstSync: Bool,
        now: Date = .now
    ) throws -> Set<String> {
        try commit {
            var deleted: Set<String> = []
            for (id, sentUpdatedAt) in sent {
                guard let session = try fetchSession(id: id) else { continue }
                let unchanged = session.updatedAt == sentUpdatedAt
                let message: String?
                switch results[id] {
                case .success:
                    session.uploadAttempts = 0
                    session.lastUploadError = nil
                    session.lastUploadFailureAt = nil
                    session.missingUploadResults = 0
                    if unchanged, !session.isActive || isFirstSync {
                        modelContext.delete(session)
                        deleted.insert(id)
                    }
                    continue
                case .failure(let error):
                    session.missingUploadResults = 0
                    message = error
                case nil:
                    guard unchanged else { continue }
                    session.missingUploadResults += 1
                    guard session.missingUploadResults >= Self.missingResultsPerFailure else { continue }
                    message = "No upload result"
                }
                // Kept for diagnostics even when the failure isn't counted.
                session.lastUploadError = message
                guard unchanged, Self.canCountFailure(after: session.lastUploadFailureAt, now: now) else { continue }
                session.missingUploadResults = 0
                session.uploadAttempts += 1
                session.lastUploadFailureAt = now
                if session.uploadAttempts >= Self.maxUploadFailures {
                    Self.logger.error(
                        "Discarding session \(id, privacy: .public) after \(session.uploadAttempts) failed uploads: \(message ?? "", privacy: .public)"
                    )
                    modelContext.delete(session)
                    deleted.insert(id)
                }
            }
            return deleted
        }
    }

    private static func canCountFailure(after last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= uploadFailureWindow
    }

    // MARK: - Private

    private func invalidateStartCaptures(for raw: String) {
        startCaptures = startCaptures.filter { $0.value.value.map { $0.key.rawValue != raw } ?? false }
    }

    /// Records a local edit or PATCH settlement: server values captured before it are dropped.
    private func advance(_ key: MediaKey) {
        generation += 1
        rowGenerations[key.rawValue] = generation
    }

    /// Merges `server` into the row (except groups in flight); `false` when the
    /// values are stale. Server times are milliseconds, so a socket event or a fetch response with
    /// the baseline's time may hold another write made before the one the baseline holds (an
    /// earlier event, or a fetch read before it); it counts as stale unless `takingTies` (a fetch
    /// issued after the baseline's values were merged, so read after the server held them).
    private func merge(_ server: ProgressBaseline, into row: LocalMediaProgress, takingTies: Bool = false) -> Bool {
        if !takingTies, let baseline = row.serverBaseline, server.lastUpdate <= baseline.lastUpdate {
            return false
        }
        var state = ProgressSyncState(row)
        guard state.merge(server, excluding: inFlight[row.key]?.groups ?? []) else { return false }
        state.write(to: row)
        return true
    }

    /// Settles the send in flight for `key`, applying `outcome` to the row it was taken from in the
    /// same save; returns whether that row was there. A row recreated for the key since isn't
    /// passed to `outcome`: its pending edits are shielded from the old PATCH's echo instead, and
    /// if that save, or the lookup telling the rows apart, fails, the send stays in flight (its
    /// groups still excluded from merges) until a retried outcome saves the shield. Once the lookup
    /// found the send's own row, or none, the send is settled even when the save fails: it stays
    /// recorded in the row, so a later fetch still recognises its echo. With `retainingOnFailure`,
    /// a failed save always leaves the send in flight, for an outcome that must not be lost.
    @discardableResult
    private func settle(
        _ key: MediaKey, sentFrom rowID: PersistentIdentifier, retainingOnFailure: Bool = false,
        applying outcome: (LocalMediaProgress) -> Void
    ) throws -> Bool {
        var ownRowOrNone = false
        do {
            let applied = try commit {
                guard let row = try fetchRow(key) else {
                    ownRowOrNone = true
                    return false
                }
                guard row.persistentModelID == rowID else {
                    var state = ProgressSyncState(row)
                    state.shieldFromObsoleteSend()
                    state.write(to: row)
                    return false
                }
                ownRowOrNone = true
                outcome(row)
                return true
            }
            settle(key)
            return applied
        } catch {
            if ownRowOrNone, !retainingOnFailure { settle(key) }
            throw error
        }
    }

    private func settle(_ key: MediaKey) {
        inFlight[key.rawValue] = nil
        advance(key)
    }

    private func fetchRow(_ key: MediaKey) throws -> LocalMediaProgress? {
        let raw = key.rawValue
        var descriptor = FetchDescriptor<LocalMediaProgress>(predicate: #Predicate { $0.key == raw })
        descriptor.fetchLimit = 1
        return try lookUp(descriptor).first
    }

    /// The rows of the given connections by key, in one lookup per connection (usually one):
    /// local rows are few, while a server snapshot may list thousands of items.
    private func fetchRows(of connections: Set<UUID>) throws -> [String: LocalMediaProgress] {
        var rows: [String: LocalMediaProgress] = [:]
        for connection in connections {
            let descriptor = FetchDescriptor<LocalMediaProgress>(
                predicate: #Predicate { $0.serverConnectionID == connection })
            for row in try lookUp(descriptor) { rows[row.key] = row }
        }
        return rows
    }

    private func lookUp(_ descriptor: FetchDescriptor<LocalMediaProgress>) throws -> [LocalMediaProgress] {
        rowFetchCount += 1
        if let failure = pendingFetchFailure {
            pendingFetchFailure = nil
            throw failure
        }
        return try modelContext.fetch(descriptor)
    }

    /// Makes the next row lookup fail with `error` (tests only).
    func failNextRowFetch(with error: any Error) {
        pendingFetchFailure = error
    }

    private func fetchRows(_ predicate: Predicate<LocalMediaProgress>) throws -> [LocalMediaProgressDTO] {
        let descriptor = FetchDescriptor(
            predicate: predicate, sortBy: [SortDescriptor(\.lastUpdate), SortDescriptor(\.key)])
        return try modelContext.fetch(descriptor).map(LocalMediaProgressDTO.init)
    }

    private func fetchSession(id: String) throws -> PendingLocalSession? {
        var descriptor = FetchDescriptor<PendingLocalSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
