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

/// A progress PATCH to send: only the groups in `values` (the dirty groups when it was taken).
public struct ProgressPatch: Sendable, Equatable {
    public var key: MediaKey
    public var values: ProgressSend
}

/// The server's per-session answer to `POST /api/session/local-all`.
public enum SessionUploadResult: Sendable, Equatable {
    case success
    case failure(String?)
}

/// The only writer of `LocalMediaProgress` and `PendingLocalSession` (ADR 0003).
///
/// Progress follows the ADR 0003 sync rules: local edits mark only the field groups they touch,
/// a PATCH carries only dirty groups, at most one PATCH is in flight per row, and server
/// progress is merged per group (``applyServerProgress(_:capturedAt:)``) after dropping values
/// captured before the row's last local edit or PATCH settlement.
@ModelActor public actor LocalProgressStore {
    /// Pending sessions are discarded after this many failed upload results.
    public static let maxUploadFailures = 5

    // In memory only: no fetch or PATCH outlives the process.
    private var generation: UInt64 = 0
    private var rowGenerations: [String: UInt64] = [:]
    private var inFlight: [String: ProgressGroups] = [:]

    private static let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "persistence")

    // MARK: - Progress

    /// Captures the current generation; pass it to ``applyServerProgress(_:capturedAt:)``.
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
        try modelContext.save()
        advance(key)
        return LocalMediaProgressDTO(row)
    }

    /// Merges server progress (from `/api/me`, an expanded item, `/api/me/progress/:id` or a
    /// socket event) into existing rows; media without a row is skipped. Values for a row edited
    /// or settled since `capturedAt` are dropped, and groups carried by a PATCH in flight aren't
    /// merged. Returns the keys whose rows were merged.
    @discardableResult
    public func applyServerProgress(
        _ updates: [MediaKey: ProgressBaseline],
        capturedAt: ProgressGeneration
    ) throws -> Set<MediaKey> {
        var merged: Set<MediaKey> = []
        for (key, server) in updates {
            if let edited = rowGenerations[key.rawValue], edited > capturedAt.value { continue }
            guard let row = try fetchRow(key) else { continue }
            var state = ProgressSyncState(row)
            guard state.merge(server, excluding: inFlight[key.rawValue] ?? []) else { continue }
            state.write(to: row)
            merged.insert(key)
        }
        if !merged.isEmpty { try modelContext.save() }
        return merged
    }

    /// Takes a snapshot of the row's dirty groups for a PATCH and records it as unacknowledged.
    /// Returns `nil` when there is no row, nothing is dirty, or a PATCH for the row is already in
    /// flight. Settle every returned patch with ``completeSend(_:serverLastUpdate:)`` or
    /// ``failSend(_:error:)``.
    public func beginSend(for key: MediaKey, now: Date = .now) throws -> ProgressPatch? {
        guard inFlight[key.rawValue] == nil, let row = try fetchRow(key) else { return nil }
        var state = ProgressSyncState(row)
        guard let send = state.beginSend() else { return nil }
        state.write(to: row)
        row.lastSyncAttemptAt = now
        try modelContext.save()
        inFlight[key.rawValue] = send.groups
        return ProgressPatch(key: key, values: send)
    }

    /// The PATCH succeeded. `serverLastUpdate` is the response's `lastUpdate`, when it has one.
    public func completeSend(_ patch: ProgressPatch, serverLastUpdate: Date?) throws {
        defer { settle(patch.key) }
        guard let row = try fetchRow(patch.key) else { return }
        var state = ProgressSyncState(row)
        state.acknowledge(patch.values, serverLastUpdate: serverLastUpdate)
        state.write(to: row)
        row.lastSyncError = nil
        try modelContext.save()
    }

    /// The PATCH failed or its response was lost. The send stays recorded as unacknowledged, and
    /// the next attempt sends the then-current values.
    public func failSend(_ patch: ProgressPatch, error: String?) throws {
        defer { settle(patch.key) }
        guard let row = try fetchRow(patch.key) else { return }
        row.lastSyncError = error
        try modelContext.save()
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
        guard let row = try fetchRow(key) else { return false }
        row.localLibraryItemID = id
        try modelContext.save()
        return true
    }

    @discardableResult
    public func deleteProgress(for key: MediaKey) throws -> Bool {
        guard let row = try fetchRow(key) else { return false }
        modelContext.delete(row)
        try modelContext.save()
        rowGenerations[key.rawValue] = nil
        return true
    }

    /// Deletes synced rows that don't belong to a download. Returns the number deleted.
    @discardableResult
    public func pruneSynced() throws -> Int {
        let predicate = #Predicate<LocalMediaProgress> { !$0.needsServerSync && $0.localLibraryItemID == nil }
        let keys = try modelContext.fetch(FetchDescriptor(predicate: predicate)).map(\.key)
        guard !keys.isEmpty else { return 0 }
        try modelContext.delete(model: LocalMediaProgress.self, where: predicate)
        try modelContext.save()
        for key in keys where inFlight[key] == nil {
            rowGenerations[key] = nil
        }
        return keys.count
    }

    // MARK: - Pending sessions

    /// Inserts the session, or updates the one with the same `id` in place.
    public func saveSession(_ session: PendingLocalSessionDTO) throws {
        if let existing = try fetchSession(id: session.id) {
            session.write(to: existing)
        } else {
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
        try modelContext.save()
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
        guard let session = try fetchSession(id: id) else { return false }
        modelContext.delete(session)
        try modelContext.save()
        return true
    }

    /// Applies the per-session results of a `local-all` upload; never the batch's HTTP status.
    ///
    /// A session is deleted only when its own result is a success, it wasn't changed while the
    /// upload was in flight (its `updatedAt` still equals the one sent), and it isn't active
    /// (active ones too on the first sync after login). A failure is counted, and the session is
    /// discarded after ``maxUploadFailures`` failures. Sessions with no result stay pending.
    ///
    /// - Parameter sent: The `updatedAt` sent for each session, by id.
    /// - Returns: The ids of the deleted sessions.
    @discardableResult
    public func settleSessionUpload(
        sent: [String: Date],
        results: [String: SessionUploadResult],
        isFirstSync: Bool
    ) throws -> Set<String> {
        var deleted: Set<String> = []
        for (id, sentUpdatedAt) in sent {
            guard let result = results[id], let session = try fetchSession(id: id) else { continue }
            switch result {
            case .success:
                guard session.updatedAt == sentUpdatedAt, !session.isActive || isFirstSync else { continue }
                modelContext.delete(session)
                deleted.insert(id)
            case .failure(let message):
                session.uploadAttempts += 1
                session.lastUploadError = message
                if session.uploadAttempts >= Self.maxUploadFailures {
                    Self.logger.error(
                        "Discarding session \(id, privacy: .public) after \(session.uploadAttempts) failed uploads: \(message ?? "", privacy: .public)"
                    )
                    modelContext.delete(session)
                    deleted.insert(id)
                }
            }
        }
        try modelContext.save()
        return deleted
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
