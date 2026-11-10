import ABSCore
import Foundation
import OSLog
import SwiftData

/// A point in `LocalProgressStore`'s edit history, captured when a progress fetch is issued or a
/// socket progress event is received. Server values are dropped for rows edited or settled since.
public struct ProgressGeneration: Sendable, Hashable, Comparable {
    let value: UInt64

    public static func < (lhs: ProgressGeneration, rhs: ProgressGeneration) -> Bool { lhs.value < rhs.value }
}

/// A progress PATCH to send: one group (`values.groups`), with its values when it was taken.
public struct ProgressPatch: Sendable, Equatable {
    public var key: MediaKey
    public var values: ProgressSend
    /// Identifies this send; settling a patch that is no longer the row's send in flight does
    /// nothing.
    public let token: UUID
}

/// Where server progress came from (``LocalProgressStore/applyServerProgress(_:capturedAt:source:)``).
public enum ServerProgressSource: Sendable, Equatable {
    /// `/api/me`, an expanded item or `/api/me/progress/:id`. A fetch that passes the generation
    /// check was issued after the row's last settlement, so it includes every acknowledged PATCH.
    case fetch
    /// A socket event (`user_updated`, `user_item_progress_updated`). It may have been emitted
    /// before an acknowledged PATCH was applied, as the PATCH's 200 has no body.
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
    /// Pending sessions are discarded after this many counted upload failures.
    public static let maxUploadFailures = 5
    /// At most one failure per session is counted in this interval.
    public static let uploadFailureWindow: TimeInterval = 60 * 60
    /// This many consecutive uploads without a result for a session count as one failure.
    public static let missingResultsPerFailure = 3

    var pendingCommitFailure: (any Error)?

    // In memory only: no fetch or PATCH outlives the process.
    private var generation: UInt64 = 0
    private var rowGenerations: [String: UInt64] = [:]
    private var inFlight: [String: (token: UUID, groups: ProgressGroups)] = [:]
    /// Groups acknowledged without a server time whose value the server hasn't confirmed since.
    private var unconfirmed: [String: ProgressGroups] = [:]

    private static let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "persistence")

    // MARK: - Progress

    /// Captures the current generation; pass it to ``applyServerProgress(_:capturedAt:source:)``.
    public func captureGeneration() -> ProgressGeneration {
        ProgressGeneration(value: generation)
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
            }
            if let localLibraryItemID { row.localLibraryItemID = localLibraryItemID }
            state.apply(edit, now: now)
            state.write(to: row)
            return LocalMediaProgressDTO(row)
        }
        advance(key)
        return saved
    }

    /// Merges server progress (from `/api/me`, an expanded item, `/api/me/progress/:id` or a
    /// socket event) into existing rows; media without a row is skipped. Values for a row edited
    /// or settled since `capturedAt` are dropped, and groups carried by a PATCH in flight aren't
    /// merged. Returns the keys whose rows were merged.
    ///
    /// A PATCH's 200 carries no server time, so after an acknowledgement a socket event can hold
    /// older values with any `lastUpdate`. Until a fetch, or a socket event holding the
    /// acknowledged value (socket events arrive in order), socket values for the acknowledged
    /// groups are ignored.
    @discardableResult
    public func applyServerProgress(
        _ updates: [MediaKey: ProgressBaseline],
        capturedAt: ProgressGeneration,
        source: ServerProgressSource
    ) throws -> Set<MediaKey> {
        let (merged, held) = try commit {
            var merged: Set<MediaKey> = []
            var held: [String: ProgressGroups] = [:]
            for (key, server) in updates {
                if let edited = rowGenerations[key.rawValue], edited > capturedAt.value { continue }
                guard let row = try fetchRow(key) else { continue }
                var state = ProgressSyncState(row)
                var server = server
                var stillHeld = source == .fetch ? [] : unconfirmed[key.rawValue] ?? []
                if let baseline = state.serverBaseline {
                    for group in ProgressGroups.each where stillHeld.contains(group) {
                        if ProgressSyncState.matches(server, baseline, group) {
                            stillHeld.remove(group)
                        } else {
                            server.copy(group, from: baseline)
                        }
                    }
                }
                guard state.merge(server, excluding: inFlight[key.rawValue]?.groups ?? []) else { continue }
                state.write(to: row)
                merged.insert(key)
                held[key.rawValue] = stillHeld
            }
            return (merged, held)
        }
        for (key, groups) in held {
            unconfirmed[key] = groups.isEmpty ? nil : groups
        }
        return merged
    }

    /// Takes a snapshot of the row's next dirty group (audio, then finished, then ebook) for a
    /// PATCH and records it as unacknowledged. Returns `nil` when there is no row, nothing is
    /// dirty, or a PATCH for the row is already in flight. Settle every returned patch with
    /// ``completeSend(_:serverLastUpdate:)`` or ``failSend(_:error:)``, then call this again for
    /// the next group.
    public func beginSend(for key: MediaKey, now: Date = .now) throws -> ProgressPatch? {
        guard inFlight[key.rawValue] == nil else { return nil }
        let send: ProgressSend? = try commit {
            guard let row = try fetchRow(key) else { return nil }
            var state = ProgressSyncState(row)
            guard let send = state.beginSend() else { return nil }
            state.write(to: row)
            row.lastSyncAttemptAt = now
            return send
        }
        guard let send else { return nil }
        let patch = ProgressPatch(key: key, values: send, token: UUID())
        inFlight[key.rawValue] = (patch.token, send.groups)
        return patch
    }

    /// The PATCH succeeded. `serverLastUpdate` is the response's `lastUpdate`, when it has one.
    /// Returns `false`, changing nothing, when `patch` is not the row's send in flight (a late or
    /// repeated response for a send already settled).
    @discardableResult
    public func completeSend(_ patch: ProgressPatch, serverLastUpdate: Date?) throws -> Bool {
        guard inFlight[patch.key.rawValue]?.token == patch.token else { return false }
        // Settled even when the save fails: the send stays recorded, so a later fetch still
        // recognises its echo.
        defer { settle(patch.key) }
        try commit {
            guard let row = try fetchRow(patch.key) else { return }
            var state = ProgressSyncState(row)
            state.acknowledge(patch.values, serverLastUpdate: serverLastUpdate)
            state.write(to: row)
            row.lastSyncError = nil
        }
        if serverLastUpdate == nil {
            unconfirmed[patch.key.rawValue, default: []].formUnion(patch.values.groups)
        }
        return true
    }

    /// The PATCH failed or its response was lost. The send stays recorded as unacknowledged, and
    /// the next attempt sends the then-current values. Returns `false`, changing nothing, when
    /// `patch` is not the row's send in flight.
    ///
    /// Call this only once the PATCH's `URLSessionTask` has really completed (ADR 0007, #53). The
    /// token stops a late outcome from settling a newer send, but it can't stop an old request
    /// that is still running from reaching the server after a newer one; the sync coordinator
    /// must not start the next send while the previous task may still be delivered.
    @discardableResult
    public func failSend(_ patch: ProgressPatch, error: String?) throws -> Bool {
        guard inFlight[patch.key.rawValue]?.token == patch.token else { return false }
        defer { settle(patch.key) }
        try commit {
            guard let row = try fetchRow(patch.key) else { return }
            row.lastSyncError = error
        }
        return true
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
            rowGenerations[key.rawValue] = nil
            unconfirmed[key.rawValue] = nil
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
            unconfirmed[key] = nil
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

    /// Records a local edit or PATCH settlement: server values captured before it are dropped.
    private func advance(_ key: MediaKey) {
        generation += 1
        rowGenerations[key.rawValue] = generation
    }

    private func settle(_ key: MediaKey) {
        inFlight[key.rawValue] = nil
        advance(key)
    }

    private func fetchRow(_ key: MediaKey) throws -> LocalMediaProgress? {
        let raw = key.rawValue
        var descriptor = FetchDescriptor<LocalMediaProgress>(predicate: #Predicate { $0.key == raw })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
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
