import ABSCore
import Foundation
import SwiftData

/// The only writer of `DownloadRecord` and `DownloadPart` (ADR 0003).
///
/// It never writes `LocalLibraryItem` or `LocalFile`: when a download completes, the engine
/// calls `LocalItemStore.upsertFromDownload(_:)` and then ``deleteRecord(_:)``.
@ModelActor public actor DownloadStore {
    /// Creates the record for `record.key`, or updates the existing one in place, keeping its
    /// `id` and `createdAt`. Parts are matched by `id`: existing ones are updated, new ones
    /// inserted and missing ones deleted.
    @discardableResult
    public func upsertRecord(_ record: DownloadRecordDTO, now: Date = .now) throws -> DownloadRecordDTO {
        let model: DownloadRecord
        if let existing = try fetchRecord(key: record.key) {
            model = existing
            model.mediaType = record.mediaType.rawValue
            model.title = record.title
            model.state = record.state.rawValue
            model.relativeDirectory = record.relativeDirectory
            model.media = record.media
            let wanted = Set(record.parts.map(\.id))
            for part in model.parts where !wanted.contains(part.id) {
                modelContext.delete(part)
            }
            let existingParts = Dictionary(
                model.parts.filter { wanted.contains($0.id) }.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var parts: [DownloadPart] = []
            for part in record.parts {
                if let existingPart = existingParts[part.id] {
                    part.apply(to: existingPart)
                    parts.append(existingPart)
                } else {
                    parts.append(part.makeModel())
                }
            }
            model.parts = parts
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
        try modelContext.save()
        return DownloadRecordDTO(model)
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
        try allRecords().filter(\.isComplete)
    }

    public func part(id: UUID) throws -> DownloadPartDTO? {
        try fetchPart(id: id).map(DownloadPartDTO.init)
    }

    /// The part whose task has `taskIdentifier`; a lookup cache only, the task's
    /// `taskDescription` (the part's `id`) is authoritative.
    public func part(taskIdentifier: Int) throws -> DownloadPartDTO? {
        let value: Int? = taskIdentifier
        var descriptor = FetchDescriptor<DownloadPart>(predicate: #Predicate { $0.taskIdentifier == value })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map(DownloadPartDTO.init)
    }

    /// Updates the part with `part.id` in place and touches its record's `updatedAt`. Returns
    /// `false` when the part doesn't exist.
    @discardableResult
    public func updatePart(_ part: DownloadPartDTO, now: Date = .now) throws -> Bool {
        guard let model = try fetchPart(id: part.id) else { return false }
        part.apply(to: model)
        model.record?.updatedAt = now
        try modelContext.save()
        return true
    }

    @discardableResult
    public func setState(_ state: DownloadState, forRecord id: UUID, now: Date = .now) throws -> Bool {
        guard let model = try fetchRecord(id: id) else { return false }
        model.state = state.rawValue
        model.updatedAt = now
        try modelContext.save()
        return true
    }

    /// Deletes the record and, by cascade, its parts. Returns what was deleted, so the caller can
    /// remove resume-data blobs for its parts, or `nil` when it doesn't exist.
    @discardableResult
    public func deleteRecord(_ id: UUID) throws -> DownloadRecordDTO? {
        guard let model = try fetchRecord(id: id) else { return nil }
        let deleted = DownloadRecordDTO(model)
        modelContext.delete(model)
        try modelContext.save()
        return deleted
    }

    // MARK: - Private

    private func fetchRecords(_ descriptor: FetchDescriptor<DownloadRecord>) throws -> [DownloadRecordDTO] {
        var descriptor = descriptor
        descriptor.sortBy = [SortDescriptor(\.createdAt), SortDescriptor(\.key)]
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

    private func fetchPart(id: UUID) throws -> DownloadPart? {
        var descriptor = FetchDescriptor<DownloadPart>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
