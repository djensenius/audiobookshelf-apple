import ABSAPI
import ABSData
import Foundation

extension DownloadManager {
    /// An item's cover that is leaving: the cover part of a cancelled record, or a deleted local
    /// item's cover.
    struct CoverSource {
        var serverPath: String
        var relativePath: String
        /// Whether the file was fetched; it is handed over completed only if it is still there.
        var isStored: Bool
        var updatedAt: Date?
        /// Whether, when no record takes it, the item's local item gets it back
        /// (``handOffCover(_:of:)``); not for a cancelled cover-only record.
        var restoresLocalItem = true
    }

    // MARK: - Deletion

    /// Deletes a downloaded item, while no enqueue, control or deletion of it runs: its local
    /// item and files (`LocalItemStore.deleteItem(id:)`), then its progress link
    /// (``LocalProgressLinking/detach(itemID:)``), then its folder with everything in it (only
    /// if its stored folder is the item's own `<connectionID>/<libraryItemID>`; otherwise only
    /// its files).
    ///
    /// While a download of the item is still pending (another podcast episode, or the item
    /// downloading again), the folder stays: only the files nothing else uses are removed, and
    /// if the cover was the item's only one, a pending episode record without a cover part gets
    /// one (see ``handOffCover(_:of:)``).
    ///
    /// - Returns: `false` when the item doesn't exist.
    /// - Throws: ``DownloadManagerError/storeFailure`` when it couldn't be read or deleted. Once
    ///   it is deleted, the hand-off and file removal are best effort: failures are logged and
    ///   leave files for the `DownloadJanitor`'s sweep (#192).
    @discardableResult
    public func deleteLocalItem(id: UUID) async throws(DownloadManagerError) -> Bool {
        guard let item = try await read({ try await self.localItems.item(id: id) }) else { return false }
        return try await holdingItem(Self.key(of: item)) { () async throws(DownloadManagerError) -> Bool in
            guard let item = try await read({ try await self.localItems.deleteItem(id: id) }) else { return false }
            await finishRemoving(item, alsoRemoving: [])
            return true
        }
    }

    /// Deletes one downloaded podcast episode, while no enqueue, control or deletion of its item
    /// runs: its files and its entry in the item (`LocalItemStore.deleteEpisode(itemID:episodeId:)`),
    /// then its progress link (``LocalProgressLinking/detach(key:)``), then its files and the
    /// folders they leave empty. The cover and the other episodes stay. When the item has no
    /// file left, the same transaction deletes it, so an episode the engine finalises into it
    /// meanwhile isn't deleted with it, and the rest goes as in ``deleteLocalItem(id:)``.
    ///
    /// - Returns: `false` when the item doesn't exist, or has neither a file nor an entry for
    ///   the episode; then nothing is deleted or detached.
    /// - Throws: ``DownloadManagerError/storeFailure`` when it couldn't be read or deleted; file
    ///   removal is best effort, as in ``deleteLocalItem(id:)``.
    @discardableResult
    public func deleteEpisode(itemID: UUID, episodeId: String) async throws(DownloadManagerError) -> Bool {
        guard let item = try await read({ try await self.localItems.item(id: itemID) }) else { return false }
        let itemKey = Self.key(of: item)
        return try await holdingItem(itemKey) { () async throws(DownloadManagerError) -> Bool in
            // Read again under the hold: a finalise can only add episodes meanwhile.
            guard let item = try await read({ try await self.localItems.item(id: itemID) }),
                item.files.contains(where: { $0.episodeId == episodeId })
                    || item.media.episodes.contains(where: { $0.id == episodeId }),
                let deletion = try await read({
                    try await self.localItems.deleteEpisode(
                        itemID: itemID, episodeId: episodeId, deletingEmptyItem: true)
                })
            else { return false }
            let key = MediaKey(
                serverConnectionID: itemKey.serverConnectionID, libraryItemId: itemKey.libraryItemId,
                episodeId: episodeId)
            await detachProgress("Couldn't detach progress from a deleted episode") { try await $0.detach(key: key) }
            let paths = deletion.removedFiles.map(\.relativePath)
            if let emptied = deletion.deletedItem {
                await finishRemoving(emptied, alsoRemoving: paths)
            } else {
                await cleanUp(after: itemKey, removing: paths, folder: nil, cover: nil)
            }
            return true
        }
    }

    /// The rest of the deletion of `item`, deleted from the store by a caller that holds it:
    /// its progress link, its cover hand-off, then its files and `extra` (files already deleted
    /// from it). Its folder goes with everything in it only when it is the folder
    /// ``DownloadLayout`` gives the item; any other stored directory (a shallower one would
    /// hold other items) loses only the item's files.
    private func finishRemoving(_ item: LocalLibraryItemDTO, alsoRemoving extra: [String]) async {
        await detachProgress("Couldn't detach progress from a deleted download") {
            try await $0.detach(itemID: item.id)
        }
        let cover = item.coverRelativePath.map { path in
            CoverSource(
                serverPath: DownloadRequests.coverPath(
                    itemID: item.libraryItemId, updatedAt: Self.coverTimestamp(item.coverUpdatedAt)),
                relativePath: path, isStored: true, updatedAt: item.coverUpdatedAt)
        }
        let paths = extra + item.files.map(\.relativePath) + (item.coverRelativePath.map { [$0] } ?? [])
        let layoutFolder = try? DownloadLayout(
            connectionID: item.serverConnectionID, libraryItemID: item.libraryItemId, locations: locations
        ).folder
        let folder = item.relativeDirectory == layoutFolder ? item.relativeDirectory : nil
        await cleanUp(after: Self.key(of: item), removing: paths, folder: folder, cover: cover)
    }

    /// The server's `updatedAt`, in milliseconds, that a cover time (a snapshot's
    /// `coverUpdatedAt`) was made from, for the cover's server path: 0, as the planner uses for
    /// none, when there is none or it is out of range.
    static func coverTimestamp(_ date: Date?) -> Int {
        guard let date else { return 0 }
        return Int(exactly: (date.timeIntervalSince1970 * 1000).rounded()) ?? 0
    }

    // MARK: - Cleaning up

    /// After media of the item of `key` was deleted: hands `cover` over (``handOffCover(_:of:)``),
    /// then removes `paths` that no local item or record still uses, and `folder` with
    /// everything in it unless one of them lies inside it. Folders left empty are removed too.
    /// Best effort: if what is still used can't be read, nothing is removed, and that is logged.
    ///
    /// Paths are compared by their ``DownloadLayout/collisionKey(_:)``, as a case-insensitive
    /// volume does: after a case-only rename on the server, a replacement's `chapter.mp3` is the
    /// stored `Chapter.mp3` there, so a reference to either keeps the file. On a case-sensitive
    /// volume, such a file is kept too, for the `DownloadJanitor`'s sweep (#192).
    func cleanUp(after key: MediaKey, removing paths: [String], folder: String?, cover: CoverSource?) async {
        let used: Set<String>
        do throws(DownloadManagerError) {
            if let cover { try await handOffCover(cover, of: key) }
            used = Set(try await usedPaths(of: key).map(DownloadLayout.collisionKey))
        } catch {
            logError("Couldn't clean up after a deletion", error)
            return
        }
        var removed = paths.filter { !used.contains(DownloadLayout.collisionKey($0)) }
        if let folder {
            // Scalars, not Characters: a name starting with a combining mark still lies inside.
            let inside = DownloadLayout.collisionKey(folder + "/").unicodeScalars
            if !used.contains(where: { $0.unicodeScalars.starts(with: inside) }) { removed = [folder] }
        }
        var directories: [URL] = []
        for path in removed {
            guard let url = try? locations.fileURL(forRelativePath: path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                // Never fetched, or already gone.
            } catch {
                logError("Couldn't remove a downloaded file", error)
            }
            directories.append(url.deletingLastPathComponent())
        }
        removeEmptyDirectories(directories)
    }

    /// Gives the item of `key` its cover again when `cover` was the only one stored or on its
    /// way (``existingCover(for:localItem:)``): the first podcast episode record of the item
    /// without a cover part, queued or downloading ones first, gets a part like `cover`'s, saved
    /// completed when its file is still there and started otherwise. Queued episodes share one
    /// cover part, so without this the episodes left would complete without a cover. (A book
    /// record always plans its own.)
    ///
    /// When no record takes it (each one left has completed, and the engine may be finalising
    /// it), and `cover.restoresLocalItem`:
    /// - a podcast's local item without a cover gets it back: the file itself while it is still
    ///   there, or else a cover-only record that fetches it again (``refetchCover(_:for:)``);
    /// - with no local item yet, it is kept in ``refusedCovers`` for the first of those records
    ///   to complete (``restoreCover(after:itemID:)``).
    func handOffCover(_ cover: CoverSource, of key: MediaKey) async throws(DownloadManagerError) {
        let itemKey = Self.itemKey(key)
        let localItem = try await read {
            try await self.localItems.item(serverConnectionID: key.serverConnectionID, libraryItemId: key.libraryItemId)
        }
        let existing = try await existingCover(for: itemKey, localItem: localItem)
        guard existing.pendingPath == nil, existing.completed == nil else { return }
        let records = try await read { try await self.store.records(serverConnectionID: key.serverConnectionID) }
            .filter {
                $0.key.libraryItemId == key.libraryItemId && $0.key.episodeId != nil
                    && !$0.parts.contains { $0.kind == .cover }
            }
        let size =
            cover.isStored
            ? (try? locations.fileURL(forRelativePath: cover.relativePath)).flatMap(DownloadLocations.fileSize(at:))
            : nil
        let part = DownloadPartDTO(
            kind: .cover, serverPath: cover.serverPath, filename: DownloadLayout.coverFilename, mimeType: "image/jpeg",
            expectedBytes: size ?? 0, bytesWritten: size ?? 0, destinationRelativePath: cover.relativePath,
            state: size == nil ? .queued : .completed)
        let isActive: (DownloadRecordDTO) -> Bool = { $0.state == .queued || $0.state == .downloading }
        for record in records.filter(isActive) + records.filter({ !isActive($0) }) {
            guard
                try await read({
                    try await self.store.addCoverPart(part, coverUpdatedAt: cover.updatedAt, toRecord: record.id)
                })
            else { continue }
            await refresh(record.id, announce: true)
            if part.state == .queued, isActive(record) { await engine.start(partIDs: [part.id]) }
            return
        }
        guard cover.restoresLocalItem else { return }
        if let localItem {
            guard localItem.mediaType == .podcast else { return }
            // Logged, not thrown: the clean-up goes on, and the files nothing uses go.
            do throws(DownloadManagerError) {
                if size != nil {
                    try await adoptCover(cover.relativePath, updatedAt: cover.updatedAt, for: localItem)
                } else {
                    try await refetchCover(cover, for: localItem)
                }
            } catch {
                logError("Couldn't give a downloaded item its cover back", error)
            }
        } else if !records.isEmpty {
            refusedCovers[itemKey] = cover
        }
    }

    /// The paths the connection's records and the item's local item still use. The records are
    /// read first: the engine finalises a download into the local item before it deletes the
    /// record, so one finalised between the two reads is in at least one of them.
    func usedPaths(of key: MediaKey) async throws(DownloadManagerError) -> Set<String> {
        let records = try await read { try await self.store.records(serverConnectionID: key.serverConnectionID) }
        await usedPathsReading?()
        let localItem = try await read {
            try await self.localItems.item(serverConnectionID: key.serverConnectionID, libraryItemId: key.libraryItemId)
        }
        var used = Set(records.flatMap(\.parts).map(\.destinationRelativePath))
        used.formUnion(localItem?.files.map(\.relativePath) ?? [])
        if let cover = localItem?.coverRelativePath { used.insert(cover) }
        return used
    }

    /// Removes each directory and then its parents, below the downloads root, while they are
    /// empty. `rmdir` refuses a directory that isn't, so a file the engine moves in meanwhile
    /// is never removed with it.
    private nonisolated func removeEmptyDirectories(_ directories: [URL]) {
        let rootDepth = locations.downloadsRoot.standardizedFileURL.pathComponents.count
        for start in directories.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            var directory = start.standardizedFileURL
            while directory.pathComponents.count > rootDepth, rmdir(directory.path(percentEncoded: false)) == 0 {
                directory = directory.deletingLastPathComponent()
            }
        }
    }

    private func detachProgress(_ message: String, _ call: (any LocalProgressLinking) async throws -> Void) async {
        guard let progressLinking else { return }
        do {
            try await call(progressLinking)
        } catch {
            logError(message, error)
        }
    }

    private static func key(of item: LocalLibraryItemDTO) -> MediaKey {
        MediaKey(serverConnectionID: item.serverConnectionID, libraryItemId: item.libraryItemId)
    }

    private static func itemKey(_ key: MediaKey) -> MediaKey {
        MediaKey(serverConnectionID: key.serverConnectionID, libraryItemId: key.libraryItemId)
    }
}
