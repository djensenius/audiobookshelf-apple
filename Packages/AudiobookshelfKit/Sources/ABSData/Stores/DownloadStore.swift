import ABSCore
import Foundation
import SwiftData

/// The only writer of `DownloadRecord` and `DownloadPart` (ADR 0003).
///
/// It never writes `LocalLibraryItem` or `LocalFile`: when a download completes, the engine
/// calls `LocalItemStore.upsertFromDownload(_:)` and then ``deleteRecord(_:)``.
@ModelActor public actor DownloadStore: StoreActor {
    public enum StoreError: Error, Equatable {
        /// The record's server connection doesn't exist (it was removed).
        case connectionNotFound(UUID)
        /// The record's `id` already belongs to the record for another key.
        case recordIDConflict(UUID)
        /// A part's `id` already belongs to another record's part, or appears twice.
        case partIDConflict(UUID)
        /// `.completed` was passed to `setPartState`; a completion must carry the file's final
        /// size, so it goes through ``DownloadStore/completePart(partID:finalBytes:now:)``.
        case completionNeedsFinalBytes
    }

    /// What ``upsertRecord(_:now:)`` saved and removed.
    public struct UpsertResult: Sendable, Equatable {
        public var record: DownloadRecordDTO
        /// Existing parts the new record no longer has, now deleted; the caller removes the
        /// resume-data blobs of those with `hasResumeData`.
        public var removedParts: [DownloadPartDTO]
    }

    var pendingCommitFailure: (any Error)?

    /// Creates the record for `record.key`, or reconciles the existing one in place, keeping its
    /// `id` and `createdAt`, in one transaction. Parts are matched by `id`: existing ones are
    /// overwritten from the DTO, new ones inserted and missing ones deleted. This whole-DTO write
    /// is only for creating and reconciling a download; the engine's updates go through
    /// ``beginRunning(partID:expecting:now:)``,
    /// ``updateProgress(partID:bytesWritten:expectedBytes:now:)``,
    /// ``setPartState(_:partID:taskIdentifier:error:hasResumeData:retryCount:requeue:now:)`` and
    /// ``completePart(partID:finalBytes:now:)``. A part passed here as `.completed` must carry its
    /// final size in `bytesWritten`.
    ///
    /// - Throws: ``StoreError/connectionNotFound(_:)`` when the connection doesn't exist, which
    ///   resolves a download racing the connection's removal (see
    ///   `ServerConnectionStore.remove(id:now:)`); ``StoreError/recordIDConflict(_:)`` or
    ///   ``StoreError/partIDConflict(_:)`` instead of letting `#Unique` merge another record's
    ///   rows.
    @discardableResult
    public func upsertRecord(_ record: DownloadRecordDTO, now: Date = .now) throws -> UpsertResult {
        try commit {
            let connectionID = record.key.serverConnectionID
            var connection = FetchDescriptor<ServerConnectionRecord>(predicate: #Predicate { $0.id == connectionID })
            connection.fetchLimit = 1
            guard try modelContext.fetchCount(connection) > 0 else {
                throw StoreError.connectionNotFound(connectionID)
            }
            let existing = try fetchRecord(key: record.key)
            if existing == nil, try fetchRecord(id: record.id) != nil {
                throw StoreError.recordIDConflict(record.id)
            }
            try checkPartIDs(record.parts.map(\.id), owner: existing?.id)

            let model: DownloadRecord
            var removed: [DownloadPartDTO] = []
            if let existing {
                model = existing
                model.mediaType = record.mediaType.rawValue
                model.title = record.title
                model.state = record.state.rawValue
                model.relativeDirectory = record.relativeDirectory
                model.media = record.media
                let wanted = Set(record.parts.map(\.id))
                for part in model.parts where !wanted.contains(part.id) {
                    removed.append(DownloadPartDTO(part))
                    modelContext.delete(part)
                }
                let existingParts = Dictionary(
                    model.parts.filter { wanted.contains($0.id) }.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                model.parts = record.parts.map { part in
                    guard let existingPart = existingParts[part.id] else { return part.makeModel() }
                    part.apply(to: existingPart)
                    return existingPart
                }
            } else {
                model = DownloadRecord(
                    id: record.id,
                    key: record.key.rawValue,
                    serverConnectionID: record.key.serverConnectionID,
                    libraryItemId: record.key.libraryItemId,
                    episodeId: record.key.episodeId,
                    mediaType: record.mediaType,
                    title: record.title,
                    state: record.state,
                    relativeDirectory: record.relativeDirectory,
                    createdAt: now,
                    media: record.media
                )
                modelContext.insert(model)
                model.parts = record.parts.map { $0.makeModel() }
            }
            model.updatedAt = now
            return UpsertResult(
                record: DownloadRecordDTO(model), removedParts: removed.sorted(by: DownloadPartDTO.precedes))
        }
    }

    public func record(id: UUID) throws -> DownloadRecordDTO? {
        try fetchRecord(id: id).map(DownloadRecordDTO.init)
    }

    public func record(key: MediaKey) throws -> DownloadRecordDTO? {
        try fetchRecord(key: key).map(DownloadRecordDTO.init)
    }

    /// Every record, oldest first (the download queue order).
    public func allRecords() throws -> [DownloadRecordDTO] {
        try fetchRecords(FetchDescriptor<DownloadRecord>())
    }

    public func records(state: DownloadState) throws -> [DownloadRecordDTO] {
        let raw = state.rawValue
        return try fetchRecords(FetchDescriptor(predicate: #Predicate { $0.state == raw }))
    }

    public func records(serverConnectionID: UUID) throws -> [DownloadRecordDTO] {
        try fetchRecords(FetchDescriptor(predicate: #Predicate { $0.serverConnectionID == serverConnectionID }))
    }

    /// Records whose parts have all completed. At launch these are finalised again
    /// (`LocalItemStore.upsertFromDownload(_:)`, then ``deleteRecord(_:)``) to repair a crash
    /// between the two steps.
    public func completedRecords() throws -> [DownloadRecordDTO] {
        let completed = DownloadPartState.completed.rawValue
        return try fetchRecords(
            FetchDescriptor(
                predicate: #Predicate { record in
                    !record.parts.isEmpty && !record.parts.contains { $0.state != completed }
                }
            )
        )
    }

    public func part(id: UUID) throws -> DownloadPartDTO? {
        try fetchPart(id: id).map(DownloadPartDTO.init)
    }

    /// The part whose task has `taskIdentifier`; a lookup cache only, the task's
    /// `taskDescription` (the part's `id`) is authoritative.
    ///
    /// ``setPartState(_:partID:taskIdentifier:error:hasResumeData:retryCount:requeue:now:)`` keeps the
    /// identifier unique, but a reconciling ``upsertRecord(_:now:)`` can repeat a stale one; then
    /// the part whose record was updated most recently wins.
    public func part(taskIdentifier: Int) throws -> DownloadPartDTO? {
        try fetchParts(taskIdentifier: taskIdentifier)
            .max { ($0.record?.updatedAt ?? .distantPast) < ($1.record?.updatedAt ?? .distantPast) }
            .map(DownloadPartDTO.init)
    }

    /// Records a part's progress; never changes its state. Returns `false` without writing when
    /// the part doesn't exist or is `.completed`: a late, throttled write must not lower the
    /// byte counts of a finished file, which `LocalItemStore` uses for its size.
    @discardableResult
    public func updateProgress(
        partID: UUID, bytesWritten: Int64, expectedBytes: Int64, now: Date = .now
    ) throws -> Bool {
        try commit {
            guard let part = try fetchPart(id: partID), part.stateValue != .completed else { return false }
            part.bytesWritten = bytesWritten
            part.expectedBytes = expectedBytes
            part.record?.updatedAt = now
            return true
        }
    }

    /// Moves a part to `state` with its task and error, keeping its progress.
    ///
    /// `.completed` is final: leaving it needs `requeue` (an explicit re-download), so a late
    /// update from a stale task can't undo a completion. Entering it goes through
    /// ``completePart(partID:finalBytes:now:)``, which records the final size. Moving to
    /// `.failed` counts a retry unless `retryCount` is supplied, in which case that count is
    /// saved with the state.
    /// `taskIdentifier` is set as given (`nil` clears it) and cleared from any other part that
    /// still has it, as task identifiers restart with each session. `error` becomes `lastError`
    /// (`nil` clears it); `hasResumeData` is kept when `nil`.
    ///
    /// - Returns: `false` when the part doesn't exist or the change was refused.
    /// - Throws: ``StoreError/completionNeedsFinalBytes`` when `state` is `.completed`.
    @discardableResult
    public func setPartState(
        _ state: DownloadPartState,
        partID: UUID,
        taskIdentifier: Int?,
        error: String? = nil,
        hasResumeData: Bool? = nil,
        retryCount: Int? = nil,
        requeue: Bool = false,
        now: Date = .now
    ) throws -> Bool {
        guard state != .completed else { throw StoreError.completionNeedsFinalBytes }
        return try commit {
            guard let part = try fetchPart(id: partID) else { return false }
            if part.stateValue == .completed, !requeue { return false }
            if let taskIdentifier {
                for other in try fetchParts(taskIdentifier: taskIdentifier) where other.id != partID {
                    other.taskIdentifier = nil
                }
            }
            if let retryCount {
                part.retryCount = retryCount
            } else if state == .failed, part.stateValue != .failed {
                part.retryCount += 1
            }
            part.state = state.rawValue
            part.taskIdentifier = taskIdentifier
            part.lastError = error
            if let hasResumeData { part.hasResumeData = hasResumeData }
            part.record?.updatedAt = now
            return true
        }
    }

    /// Starts a part, in one write: moves it from one of `expecting` to `.running`, and its
    /// record from `.queued` to `.downloading`. The engine creates a transfer only when this
    /// returns `true`, so a launch from a stale read can't restart a part that has since
    /// completed, been stopped, failed for good or been deleted. The compare-and-set only holds
    /// when the engine and the app share one `DownloadStore` actor.
    ///
    /// `expecting` is the states the caller may start the part from: `.queued`, and `.failed`
    /// for a retry. The change is refused when the part or its record doesn't exist, the part
    /// is in another state or `.completed` (even if `expecting` has it), or the record is
    /// `.paused` (stopped) or `.failed` (failed for good). The task identifier and error are
    /// cleared; the caller records the new task's identifier with
    /// ``setPartState(_:partID:taskIdentifier:error:hasResumeData:retryCount:requeue:now:)``. Progress, the
    /// retry count and the resume-data flag are kept.
    ///
    /// - Returns: whether the part was started.
    public func beginRunning(partID: UUID, expecting: Set<DownloadPartState>, now: Date = .now) throws -> Bool {
        try commit {
            guard let part = try fetchPart(id: partID), let record = part.record, let state = part.stateValue,
                state != .completed, expecting.contains(state)
            else { return false }
            switch record.stateValue {
            case .queued: record.state = DownloadState.downloading.rawValue
            case .downloading: break
            case .paused, .failed, nil: return false
            }
            part.state = DownloadPartState.running.rawValue
            part.taskIdentifier = nil
            part.lastError = nil
            record.updatedAt = now
            return true
        }
    }

    /// Queues a part again, in one write, only while it is in one of `expecting`: the engine
    /// queues a part it read as `.running` without a transfer, and must not overwrite a state
    /// written since (a part that failed for good, say). The change is refused when the part
    /// doesn't exist, is in another state, or is `.completed` (even if `expecting` has it; see
    /// ``setPartState(_:partID:taskIdentifier:error:hasResumeData:retryCount:requeue:now:)``). The task
    /// identifier and error are cleared; progress, the retry count and the resume-data flag
    /// are kept.
    ///
    /// - Returns: whether the part was queued.
    @discardableResult
    public func queuePart(partID: UUID, expecting: Set<DownloadPartState>, now: Date = .now) throws -> Bool {
        try commit {
            guard let part = try fetchPart(id: partID), let state = part.stateValue, state != .completed,
                expecting.contains(state)
            else { return false }
            part.state = DownloadPartState.queued.rawValue
            part.taskIdentifier = nil
            part.lastError = nil
            part.record?.updatedAt = now
            return true
        }
    }

    /// Changes a part's resume-data flag and retry count, each when given, in one write. Its
    /// state, task identifier, error and progress are left as they are, so a change made from an
    /// older read can't undo a transition written since (a part that failed meanwhile, say).
    ///
    /// - Returns: `false` when the part doesn't exist or is `.completed`.
    @discardableResult
    public func updatePart(
        partID: UUID, hasResumeData: Bool? = nil, retryCount: Int? = nil, now: Date = .now
    ) throws -> Bool {
        try commit {
            guard let part = try fetchPart(id: partID), part.stateValue != .completed else { return false }
            if let hasResumeData { part.hasResumeData = hasResumeData }
            if let retryCount { part.retryCount = retryCount }
            part.record?.updatedAt = now
            return true
        }
    }

    /// Marks a part `.completed` with its final size, in one write: `bytesWritten` becomes
    /// `finalBytes`, and so does `expectedBytes` when it was unknown (≤ 0, as
    /// `NSURLSessionTransferSizeUnknown`). `finalBytes` is authoritative, even below the last
    /// progress (a throttled write may not have landed), and
    /// ``updateProgress(partID:bytesWritten:expectedBytes:now:)`` can't change it afterwards.
    /// The engine takes it from the file it moved in `didFinishDownloadingTo` (its size, or the
    /// task's `countOfBytesReceived`).
    ///
    /// The task identifier, error and resume-data flag are cleared; the caller deletes the part's
    /// resume-data blob, if any. Completing an already completed part records the new size.
    ///
    /// - Returns: `false` when the part doesn't exist.
    @discardableResult
    public func completePart(partID: UUID, finalBytes: Int64, now: Date = .now) throws -> Bool {
        try commit {
            guard let part = try fetchPart(id: partID) else { return false }
            part.state = DownloadPartState.completed.rawValue
            part.bytesWritten = finalBytes
            if part.expectedBytes <= 0 { part.expectedBytes = finalBytes }
            part.taskIdentifier = nil
            part.lastError = nil
            part.hasResumeData = false
            part.record?.updatedAt = now
            return true
        }
    }

    /// Sets the whole download's state. Every transition is allowed: the engine drives it
    /// (queued, downloading, paused, failed and back), and completion is not a record state but
    /// derived from the parts (``DownloadRecordDTO/isComplete``). Returns `false` when the record
    /// doesn't exist.
    @discardableResult
    public func setState(_ state: DownloadState, forRecord id: UUID, now: Date = .now) throws -> Bool {
        try commit {
            guard let model = try fetchRecord(id: id) else { return false }
            model.state = state.rawValue
            model.updatedAt = now
            return true
        }
    }

    /// Changes a record's state only while it is in one of `expecting`, so a failure cannot
    /// overwrite a concurrent pause or resume.
    @discardableResult
    public func setState(
        _ state: DownloadState, forRecord id: UUID, expecting: Set<DownloadState>, now: Date = .now
    ) throws -> Bool {
        try commit {
            guard let model = try fetchRecord(id: id), let current = model.stateValue, expecting.contains(current)
            else { return false }
            model.state = state.rawValue
            model.updatedAt = now
            return true
        }
    }

    /// Deletes the record and, by cascade, its parts. Returns what was deleted, so the caller can
    /// remove resume-data blobs for its parts, or `nil` when it doesn't exist.
    @discardableResult
    public func deleteRecord(_ id: UUID) throws -> DownloadRecordDTO? {
        try commit {
            guard let model = try fetchRecord(id: id) else { return nil }
            let deleted = DownloadRecordDTO(model)
            modelContext.delete(model)
            return deleted
        }
    }

    // MARK: - Private

    private func fetchRecords(_ descriptor: FetchDescriptor<DownloadRecord>) throws -> [DownloadRecordDTO] {
        var descriptor = descriptor
        descriptor.sortBy = [SortDescriptor(\.createdAt), SortDescriptor(\.key)]
        descriptor.relationshipKeyPathsForPrefetching = [\.parts]
        return try modelContext.fetch(descriptor).map(DownloadRecordDTO.init)
    }

    private func fetchRecord(id: UUID) throws -> DownloadRecord? {
        var descriptor = FetchDescriptor<DownloadRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchRecord(key: MediaKey) throws -> DownloadRecord? {
        let raw = key.rawValue
        var descriptor = FetchDescriptor<DownloadRecord>(predicate: #Predicate { $0.key == raw })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchParts(taskIdentifier: Int) throws -> [DownloadPart] {
        let value: Int? = taskIdentifier
        return try modelContext.fetch(
            FetchDescriptor<DownloadPart>(predicate: #Predicate { $0.taskIdentifier == value }))
    }

    /// Throws when a part id repeats or belongs to a part of a record other than `owner`.
    private func checkPartIDs(_ ids: [UUID], owner: UUID?) throws {
        var seen: Set<UUID> = []
        for id in ids {
            guard seen.insert(id).inserted else { throw StoreError.partIDConflict(id) }
            if let part = try fetchPart(id: id), part.record?.id != owner || owner == nil {
                throw StoreError.partIDConflict(id)
            }
        }
    }

    private func fetchPart(id: UUID) throws -> DownloadPart? {
        var descriptor = FetchDescriptor<DownloadPart>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
