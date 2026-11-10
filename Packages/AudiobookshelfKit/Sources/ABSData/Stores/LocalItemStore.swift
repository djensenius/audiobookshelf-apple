import ABSCore
import Foundation
import SwiftData

/// The only writer of `LocalLibraryItem` and `LocalFile` (ADR 0003).
@ModelActor public actor LocalItemStore {
    public enum StoreError: Error, Equatable {
        /// The download's server connection doesn't exist, so the item's server address and
        /// user are unknown.
        case connectionNotFound(UUID)
    }

    /// Turns a completed download into a local item, idempotently.
    ///
    /// The item is looked up by `[serverConnectionID, libraryItemId]` and updated in place
    /// (keeping its `id` and `addedAt`), or inserted. Audio and ebook parts become files; a file
    /// with the same relative path keeps its `id`, and files of the same download (the whole book,
    /// or the same podcast episode) that the download no longer has are deleted. For podcasts the
    /// downloaded episode is merged into the item's snapshot, so other episodes stay. A cover part
    /// sets `coverRelativePath`.
    ///
    /// - Parameter coverUpdatedAt: The server's cover timestamp; `nil` keeps the stored one.
    @discardableResult
    public func upsertFromDownload(
        _ download: DownloadRecordDTO,
        coverUpdatedAt: Date? = nil,
        now: Date = .now
    ) throws -> LocalLibraryItemDTO {
        let key = download.key
        guard let connection = try fetchConnection(id: key.serverConnectionID) else {
            throw StoreError.connectionNotFound(key.serverConnectionID)
        }
        let coverPath = download.parts.last { $0.kind == .cover }?.destinationRelativePath
        let files = download.parts.compactMap(Self.file(from:))

        let item: LocalLibraryItem
        if let existing = try fetchItem(serverConnectionID: key.serverConnectionID, libraryItemId: key.libraryItemId) {
            item = existing
            item.media = Self.merging(download.media, into: existing.media, episodeId: key.episodeId)
            reconcileFiles(of: item, with: files, episodeId: key.episodeId)
        } else {
            item = LocalLibraryItem(
                serverConnectionID: key.serverConnectionID,
                serverAddress: connection.address,
                serverUserId: connection.userId,
                libraryItemId: key.libraryItemId,
                mediaType: download.mediaType,
                title: download.title,
                relativeDirectory: download.relativeDirectory,
                addedAt: now,
                media: download.media
            )
            modelContext.insert(item)
            item.files = files.map(Self.makeModel)
        }
        item.serverAddress = connection.address
        item.serverUserId = connection.userId
        item.mediaType = download.mediaType.rawValue
        item.title = download.title
        item.relativeDirectory = download.relativeDirectory
        let authors = download.media.metadata.authors
        item.authorName = authors.isEmpty ? nil : authors.joined(separator: ", ")
        if let coverPath { item.coverRelativePath = coverPath }
        if let coverUpdatedAt { item.coverUpdatedAt = coverUpdatedAt }
        item.updatedAt = now
        try modelContext.save()
        return LocalLibraryItemDTO(item)
    }

    public func item(id: UUID) throws -> LocalLibraryItemDTO? {
        try fetchItem(id: id).map(LocalLibraryItemDTO.init)
    }

    public func item(serverConnectionID: UUID, libraryItemId: String) throws -> LocalLibraryItemDTO? {
        try fetchItem(serverConnectionID: serverConnectionID, libraryItemId: libraryItemId)
            .map(LocalLibraryItemDTO.init)
    }

    /// Every local item, most recently added first.
    public func allItems() throws -> [LocalLibraryItemDTO] {
        try fetchItems(FetchDescriptor<LocalLibraryItem>())
    }

    public func items(serverConnectionID: UUID) throws -> [LocalLibraryItemDTO] {
        try fetchItems(FetchDescriptor(predicate: #Predicate { $0.serverConnectionID == serverConnectionID }))
    }

    /// Records a refreshed cover (ADR 0005). Returns `false` when the item doesn't exist.
    @discardableResult
    public func updateCover(
        itemID: UUID,
        relativePath: String?,
        updatedAt: Date?,
        now: Date = .now
    ) throws -> Bool {
        guard let item = try fetchItem(id: itemID) else { return false }
        item.coverRelativePath = relativePath
        item.coverUpdatedAt = updatedAt
        item.updatedAt = now
        try modelContext.save()
        return true
    }

    /// Removes one downloaded podcast episode: its files and its snapshot entry. Returns the
    /// deleted files so the caller can remove them from disk.
    @discardableResult
    public func deleteEpisode(itemID: UUID, episodeId: String, now: Date = .now) throws -> [LocalFileDTO] {
        guard let item = try fetchItem(id: itemID) else { return [] }
        let removed = item.files.filter { $0.episodeId == episodeId }
        let deleted = removed.map(LocalFileDTO.init)
        for file in removed {
            modelContext.delete(file)
        }
        item.files.removeAll { $0.episodeId == episodeId }
        item.media.episodes.removeAll { $0.id == episodeId }
        item.updatedAt = now
        try modelContext.save()
        return deleted
    }

    /// Deletes the item and, by cascade, its files. Returns what was deleted so the caller can
    /// remove the files from disk and detach progress (`LocalProgressStore`), or `nil` when it
    /// doesn't exist.
    @discardableResult
    public func deleteItem(id: UUID) throws -> LocalLibraryItemDTO? {
        guard let item = try fetchItem(id: id) else { return nil }
        let deleted = LocalLibraryItemDTO(item)
        modelContext.delete(item)
        try modelContext.save()
        return deleted
    }

    // MARK: - Private

    private static func file(from part: DownloadPartDTO) -> LocalFileDTO? {
        let kind: LocalFileKind
        switch part.kind {
        case .audio: kind = .audio
        case .ebook: kind = .ebook
        case .cover: return nil
        }
        return LocalFileDTO(
            kind: kind,
            relativePath: part.destinationRelativePath,
            filename: part.filename,
            mimeType: part.mimeType,
            size: max(part.bytesWritten, part.expectedBytes),
            serverIno: part.serverIno,
            trackIndex: part.trackIndex,
            episodeId: part.episodeId
        )
    }

    private static func makeModel(_ file: LocalFileDTO) -> LocalFile {
        LocalFile(
            id: file.id,
            kind: file.kind,
            relativePath: file.relativePath,
            filename: file.filename,
            mimeType: file.mimeType,
            size: file.size,
            serverIno: file.serverIno,
            trackIndex: file.trackIndex,
            episodeId: file.episodeId
        )
    }

    /// A book download replaces the snapshot; a podcast episode download replaces the metadata and
    /// adds (or replaces) its episodes, keeping the episodes downloaded earlier.
    private static func merging(
        _ downloaded: LocalMediaSnapshot,
        into existing: LocalMediaSnapshot,
        episodeId: String?
    ) -> LocalMediaSnapshot {
        guard episodeId != nil else { return downloaded }
        var merged = downloaded
        let newIDs = Set(downloaded.episodes.map(\.id))
        merged.episodes = existing.episodes.filter { !newIDs.contains($0.id) } + downloaded.episodes
        return merged
    }

    /// Updates files with the same relative path in place, inserts new ones, and deletes the
    /// download's old files (same `episodeId`) that it no longer has.
    private func reconcileFiles(of item: LocalLibraryItem, with files: [LocalFileDTO], episodeId: String?) {
        let wantedPaths = Set(files.map(\.relativePath))
        var kept: [LocalFile] = []
        var byPath: [String: LocalFile] = [:]
        for file in item.files {
            if wantedPaths.contains(file.relativePath), byPath[file.relativePath] == nil {
                byPath[file.relativePath] = file
            } else if file.episodeId == episodeId || wantedPaths.contains(file.relativePath) {
                modelContext.delete(file)
            } else {
                kept.append(file)
            }
        }
        for file in files {
            if let existing = byPath[file.relativePath] {
                existing.kind = file.kind.rawValue
                existing.filename = file.filename
                existing.mimeType = file.mimeType
                existing.size = file.size
                existing.serverIno = file.serverIno
                existing.trackIndex = file.trackIndex
                existing.episodeId = file.episodeId
                kept.append(existing)
            } else {
                kept.append(Self.makeModel(file))
            }
        }
        item.files = kept
    }

    private func fetchItems(_ descriptor: FetchDescriptor<LocalLibraryItem>) throws -> [LocalLibraryItemDTO] {
        var descriptor = descriptor
        descriptor.sortBy = [SortDescriptor(\.addedAt, order: .reverse), SortDescriptor(\.libraryItemId)]
        return try modelContext.fetch(descriptor).map(LocalLibraryItemDTO.init)
    }

    private func fetchItem(id: UUID) throws -> LocalLibraryItem? {
        var descriptor = FetchDescriptor<LocalLibraryItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchItem(serverConnectionID: UUID, libraryItemId: String) throws -> LocalLibraryItem? {
        var descriptor = FetchDescriptor<LocalLibraryItem>(
            predicate: #Predicate { $0.serverConnectionID == serverConnectionID && $0.libraryItemId == libraryItemId }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// Reads (never writes) the connection, owned by `ServerConnectionStore`.
    private func fetchConnection(id: UUID) throws -> ServerConnectionRecord? {
        var descriptor = FetchDescriptor<ServerConnectionRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
