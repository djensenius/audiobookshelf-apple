import ABSCore
import Foundation
import SwiftData

/// The only writer of `LocalLibraryItem` and `LocalFile` (ADR 0003).
@ModelActor public actor LocalItemStore: StoreActor {
    public enum StoreError: Error, Equatable {
        /// The download's server connection doesn't exist, so the item's server address and
        /// user are unknown.
        case connectionNotFound(UUID)
        /// Some of the download's parts haven't completed.
        case incompleteDownload
        /// A cover-only download's local item doesn't exist (it was deleted meanwhile).
        case itemNotFound
    }

    /// What ``deleteEpisode(itemID:episodeId:deletingEmptyItem:now:)`` removed.
    public struct EpisodeDeletion: Sendable, Equatable {
        /// The deleted files, to remove from disk (empty when the episode had none).
        public var removedFiles: [LocalFileDTO]
        /// Whether the item has no files left, so the caller can delete it.
        public var itemIsEmpty: Bool
        /// The item as it was deleted, with no files, when `deletingEmptyItem` deleted it too.
        public var deletedItem: LocalLibraryItemDTO?
    }

    var pendingCommitFailure: (any Error)?

    /// Turns a completed download into a local item, idempotently, in one transaction.
    ///
    /// The item is looked up by `[serverConnectionID, libraryItemId]` and updated in place
    /// (keeping its `id` and `addedAt`), or inserted. Audio and ebook parts become files; a file
    /// with the same relative path keeps its `id`, and files of the same download (the whole book,
    /// or the same podcast episode) that the download no longer has are deleted. For podcasts the
    /// downloaded episode is merged into the item's snapshot, so other episodes stay; the item's
    /// title is the podcast's (`media.metadata.title`, not the episode download's `title`) and its
    /// `relativeDirectory` is set when it is created and never moved. A cover part sets
    /// `coverRelativePath`.
    ///
    /// A cover-only download (`DownloadRecordDTO.isCoverOnly`) only sets the existing item's
    /// cover and its time, and only while it has no cover; its media, files and title stay as
    /// they are. A file it fetched that the item doesn't use is left for the janitor's sweep.
    ///
    /// - Throws: ``StoreError/incompleteDownload`` unless every part completed,
    ///   ``StoreError/connectionNotFound(_:)`` when the connection doesn't exist, and
    ///   ``StoreError/itemNotFound`` for a cover-only download without its item.
    /// - Parameter coverUpdatedAt: The server's cover timestamp; `nil` falls back to the
    ///   snapshot's `coverUpdatedAt`, and when both are `nil` the stored one is kept. A re-download
    ///   whose snapshot has no timestamp (saved before snapshot version 2) keeps the old value.
    @discardableResult
    public func upsertFromDownload(
        _ download: DownloadRecordDTO,
        coverUpdatedAt: Date? = nil,
        now: Date = .now
    ) throws -> LocalLibraryItemDTO {
        guard download.isComplete else { throw StoreError.incompleteDownload }
        let key = download.key
        let isEpisode = key.episodeId != nil
        let title = isEpisode ? download.media.metadata.title : download.title
        let coverPath = download.parts.last { $0.kind == .cover }?.destinationRelativePath
        let files = download.parts.compactMap { Self.file(from: $0, episodeId: key.episodeId) }
        if download.isCoverOnly {
            return try commit {
                guard
                    let item = try fetchItem(
                        serverConnectionID: key.serverConnectionID, libraryItemId: key.libraryItemId)
                else { throw StoreError.itemNotFound }
                // A cover the item got meanwhile (an episode carried one) is kept.
                Self.setCoverIfMissing(
                    item, relativePath: coverPath, updatedAt: coverUpdatedAt ?? download.media.coverUpdatedAt, now: now)
                return LocalLibraryItemDTO(item)
            }
        }
        return try commit {
            guard let connection = try fetchConnection(id: key.serverConnectionID) else {
                throw StoreError.connectionNotFound(key.serverConnectionID)
            }
            let item: LocalLibraryItem
            if let existing = try fetchItem(
                serverConnectionID: key.serverConnectionID, libraryItemId: key.libraryItemId)
            {
                item = existing
                item.media = Self.merging(download.media, into: existing.media, episodeId: key.episodeId)
                reconcileFiles(of: item, with: files, episodeId: key.episodeId)
                if !isEpisode { item.relativeDirectory = download.relativeDirectory }
            } else {
                item = LocalLibraryItem(
                    serverConnectionID: key.serverConnectionID,
                    serverAddress: connection.address,
                    serverUserId: connection.userId,
                    libraryItemId: key.libraryItemId,
                    mediaType: download.mediaType,
                    title: title,
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
            item.title = title
            let authors = download.media.metadata.authors
            item.authorName = authors.isEmpty ? nil : authors.joined(separator: ", ")
            if let coverPath { item.coverRelativePath = coverPath }
            if let coverUpdatedAt = coverUpdatedAt ?? download.media.coverUpdatedAt {
                item.coverUpdatedAt = coverUpdatedAt
            }
            item.updatedAt = now
            return LocalLibraryItemDTO(item)
        }
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
        try commit {
            guard let item = try fetchItem(id: itemID) else { return false }
            item.coverRelativePath = relativePath
            item.coverUpdatedAt = updatedAt
            item.updatedAt = now
            return true
        }
    }

    /// Makes `relativePath` the item's cover, with `updatedAt` when known, unless the item has
    /// a cover: checked and set in one transaction, so a cover a finalised download gave it
    /// meanwhile is kept. Returns `false` when it has one or the item doesn't exist.
    @discardableResult
    public func setCoverIfMissing(
        itemID: UUID, relativePath: String, updatedAt: Date?, now: Date = .now
    ) throws -> Bool {
        try commit {
            guard let item = try fetchItem(id: itemID) else { return false }
            return Self.setCoverIfMissing(item, relativePath: relativePath, updatedAt: updatedAt, now: now)
        }
    }

    @discardableResult
    private static func setCoverIfMissing(
        _ item: LocalLibraryItem, relativePath: String?, updatedAt: Date?, now: Date
    ) -> Bool {
        guard item.coverRelativePath == nil else { return false }
        item.coverRelativePath = relativePath
        if let updatedAt { item.coverUpdatedAt = updatedAt }
        item.updatedAt = now
        return true
    }

    /// Removes one downloaded podcast episode, its files and its snapshot entry, in one
    /// transaction. Returns the deleted files, so the caller can remove them from disk, and
    /// whether the item is now empty, so the caller can delete it; `nil` when the item doesn't
    /// exist. With `deletingEmptyItem`, an item left without files is deleted in the same
    /// transaction, and returned: an episode saved into it meanwhile (a download finalised by
    /// ``upsertFromDownload(_:coverUpdatedAt:now:)``) either keeps it or comes after, as a new item.
    @discardableResult
    public func deleteEpisode(
        itemID: UUID, episodeId: String, deletingEmptyItem: Bool = false, now: Date = .now
    ) throws -> EpisodeDeletion? {
        try commit {
            guard let item = try fetchItem(id: itemID) else { return nil }
            let removed = item.files.filter { $0.episodeId == episodeId }
            let deleted = removed.map(LocalFileDTO.init)
            for file in removed {
                modelContext.delete(file)
            }
            item.files.removeAll { $0.episodeId == episodeId }
            item.media.episodes.removeAll { $0.id == episodeId }
            item.updatedAt = now
            var deletion = EpisodeDeletion(removedFiles: deleted, itemIsEmpty: item.files.isEmpty)
            if deletingEmptyItem, deletion.itemIsEmpty {
                deletion.deletedItem = LocalLibraryItemDTO(item)
                modelContext.delete(item)
            }
            return deletion
        }
    }

    /// Deletes the item and, by cascade, its files. Returns what was deleted so the caller can
    /// remove the files from disk and detach progress (`LocalProgressStore`), or `nil` when it
    /// doesn't exist.
    @discardableResult
    public func deleteItem(id: UUID) throws -> LocalLibraryItemDTO? {
        try commit {
            guard let item = try fetchItem(id: id) else { return nil }
            let deleted = LocalLibraryItemDTO(item)
            modelContext.delete(item)
            return deleted
        }
    }

    // MARK: - Private

    /// The file for an audio or ebook part. An episode download's files always carry its
    /// episode id, even when the part doesn't. Its size is the completed part's `bytesWritten`,
    /// the final size `DownloadStore.completePart(partID:finalBytes:now:)` recorded.
    private static func file(from part: DownloadPartDTO, episodeId: String?) -> LocalFileDTO? {
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
            size: part.bytesWritten,
            serverIno: part.serverIno,
            trackIndex: part.trackIndex,
            episodeId: part.episodeId ?? episodeId
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
        merged.coverUpdatedAt = downloaded.coverUpdatedAt ?? existing.coverUpdatedAt
        let newIDs = Set(downloaded.episodes.map(\.id))
        merged.episodes = existing.episodes.filter { !newIDs.contains($0.id) } + downloaded.episodes
        return merged
    }

    /// Updates files with the same relative path in place, inserts new ones, and deletes the
    /// download's old files (same `episodeId`) that it no longer has. Runs inside the caller's
    /// ``commit(_:)`` transaction.
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
        descriptor.relationshipKeyPathsForPrefetching = [\.files]
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
