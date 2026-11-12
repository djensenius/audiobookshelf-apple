import ABSData
import Foundation

extension DownloadManager {
    // MARK: - Restoring a cover

    /// After the episode of `key` completed into the local item `itemID`, while its item is
    /// held: gives the local item a cover when it has none, so a cover the hand-off couldn't
    /// give to any record (``handOffCover(_:of:)``) isn't lost for good:
    /// 1. nothing happens while a queued or downloading record of the item will fetch one;
    /// 2. a cover another record has fetched, or one still on disk where the cover kept in
    ///    ``refusedCovers`` or the item's `cover.jpg` lies, is used as it is;
    /// 3. otherwise a paused or failed refetch is resumed, or else the kept cover is fetched
    ///    again (``refetchCover(_:for:)``).
    ///
    /// Without any of those, nothing is fetched: the item may have no cover on the server.
    /// When the item has or gets a cover without the refetch, a paused or failed refetch is
    /// deleted (``dropStalledRefetch(_:)``), so it doesn't stay hidden for good. The kept cover
    /// is dropped once this got that far; a failed read keeps it for the next completion. Best
    /// effort: failures are logged.
    func restoreCover(after key: MediaKey, itemID: UUID) async {
        let itemKey = MediaKey(serverConnectionID: key.serverConnectionID, libraryItemId: key.libraryItemId)
        do throws(DownloadManagerError) {
            try await restoreCover(of: itemID, itemKey: itemKey, refused: refusedCovers[itemKey])
            refusedCovers[itemKey] = nil
        } catch {
            logError("Couldn't restore a downloaded item's cover", error)
        }
    }

    private func restoreCover(
        of itemID: UUID, itemKey: MediaKey, refused: CoverSource?
    ) async throws(DownloadManagerError) {
        guard let item = try await read({ try await self.localItems.item(id: itemID) }) else { return }
        guard item.coverRelativePath == nil else { return try await dropStalledRefetch(itemKey) }
        let existing = try await existingCover(for: itemKey, localItem: item)
        guard existing.pendingPath == nil else { return }
        let updatedAt = refused?.updatedAt ?? item.coverUpdatedAt
        if let completed = existing.completed {
            try await adoptCover(completed.destinationRelativePath, updatedAt: updatedAt, for: item)
            return try await dropStalledRefetch(itemKey)
        }
        let layoutPath = try? DownloadLayout(
            connectionID: item.serverConnectionID, libraryItemID: item.libraryItemId, locations: locations
        ).coverPath()
        if let stored = [refused?.relativePath, layoutPath].compactMap({ $0 }).first(where: fileExists) {
            try await adoptCover(stored, updatedAt: updatedAt, for: item)
            try await dropStalledRefetch(itemKey)
        } else {
            try await refetchCover(refused, for: item)
        }
    }

    /// Makes the file at `path`, on disk, the local item's cover.
    func adoptCover(
        _ path: String, updatedAt: Date?, for item: LocalLibraryItemDTO
    ) async throws(DownloadManagerError) {
        _ = try await read {
            try await self.localItems.updateCover(itemID: item.id, relativePath: path, updatedAt: updatedAt)
        }
    }

    /// Fetches the cover of `item` again, under its item-level key, while its caller holds the
    /// item:
    /// - a cover-only record (``DownloadRecordDTO/isCoverOnly``) already there that is paused or
    ///   failed is resumed: it is hidden from the user, who can't; a queued or downloading one
    ///   is left alone. Like the insert below, nothing is resumed while the connection is signed
    ///   out or disconnected (``DownloadStore/isSignedIn(serverConnectionID:)``);
    /// - otherwise, with `cover`, a new cover-only record that fetches it is saved and started.
    ///   Nothing is saved while the connection is signed out or disconnected, or the key is
    ///   taken (``DownloadStore/insertRecordIfSignedIn(_:now:)``).
    ///
    /// Once complete, the engine sets the cover as the local item's. Like any record, it is
    /// reported with ``DownloadManagerEvent/recordChanged(_:)``; once complete with
    /// ``DownloadManagerEvent/recordRemoved(recordID:)``, as it downloaded no media.
    func refetchCover(_ cover: CoverSource?, for item: LocalLibraryItemDTO) async throws(DownloadManagerError) {
        let key = MediaKey(serverConnectionID: item.serverConnectionID, libraryItemId: item.libraryItemId)
        if let current = try await read({ try await self.store.record(key: key) }) {
            guard current.isCoverOnly, current.state == .paused || current.state == .failed,
                try await read({ try await self.store.isSignedIn(serverConnectionID: key.serverConnectionID) }),
                try await read({ try await self.engine.resume(recordID: current.id) })
            else { return }
            await refresh(current.id, announce: true)
            return
        }
        guard let cover else { return }
        let part = DownloadPartDTO(
            kind: .cover, serverPath: cover.serverPath, filename: DownloadLayout.coverFilename, mimeType: "image/jpeg",
            expectedBytes: 0, bytesWritten: 0, destinationRelativePath: cover.relativePath, state: .queued)
        let plan = DownloadRecordDTO(
            key: key, mediaType: item.mediaType, title: item.title, relativeDirectory: item.relativeDirectory,
            media: LocalMediaSnapshot(metadata: item.media.metadata, coverUpdatedAt: cover.updatedAt), parts: [part])
        guard let record = try await read({ try await self.store.insertRecordIfSignedIn(plan) }) else { return }
        track(record)
        emit(.recordChanged(record))
        await engine.start(partIDs: [part.id])
    }

    /// A cover-only record whose fetch failed for good, while its item is held: deleted and
    /// reported removed, as the user, who doesn't see it, can't retry it, and while it stays it
    /// keeps its connection's records from being purged. Its cover is kept in
    /// ``refusedCovers``, so the item's next episode completion fetches it again. Best effort:
    /// failures are logged, and leave the failed record for ``refetchCover(_:for:)`` to resume.
    func dropFailedRefetch(_ recordID: UUID) async {
        do throws(DownloadManagerError) {
            guard let first = try await read({ try await self.store.record(id: recordID) }) else { return }
            try await holdingItem(first.key) { () async throws(DownloadManagerError) in
                // Read again: it may have been resumed or cancelled meanwhile.
                guard let record = try await read({ try await self.store.record(id: recordID) }),
                    record.isCoverOnly, record.state == .failed,
                    let deleted = try await deleteRefetch(record)
                else { return }
                if let part = deleted.parts.first {
                    refusedCovers[deleted.key] = CoverSource(
                        serverPath: part.serverPath, relativePath: part.destinationRelativePath, isStored: false,
                        updatedAt: deleted.media.coverUpdatedAt)
                }
            }
        } catch {
            logError("Couldn't drop a cover download that failed", error)
        }
    }

    /// While the item of `itemKey` is held and its local item has a cover: deletes its
    /// cover-only record if one is paused or failed, as nothing would resume or remove it.
    private func dropStalledRefetch(_ itemKey: MediaKey) async throws(DownloadManagerError) {
        guard let record = try await read({ try await self.store.record(key: itemKey) }),
            record.isCoverOnly, record.state == .paused || record.state == .failed
        else { return }
        _ = try await deleteRefetch(record)
    }

    /// Stops and deletes the unfinished cover-only `record`, then reports it removed.
    /// - Returns: the deleted record, or `nil` when it had completed or was gone.
    private func deleteRefetch(_ record: DownloadRecordDTO) async throws(DownloadManagerError) -> DownloadRecordDTO? {
        await engine.stop(partIDs: record.parts.map(\.id), keepingResumeData: false)
        guard
            case .deleted(let deleted) = try await read({ try await self.store.deleteUnfinishedRecord(record.id) })
        else { return nil }
        reportRemoved(record.id)
        for part in deleted.parts { locations.clearTransferMarker(partID: part.id) }
        return deleted
    }

    /// After an episode of the item of `key` completed into a deleted item or episode, while
    /// the item is held: the cover kept for the item's next completion is dropped once no record
    /// of the item is left to complete, so it isn't given to a local item made later.
    func dropRefusedCoverIfUnused(_ key: MediaKey) async {
        let itemKey = MediaKey(serverConnectionID: key.serverConnectionID, libraryItemId: key.libraryItemId)
        guard refusedCovers[itemKey] != nil else { return }
        do throws(DownloadManagerError) {
            let records = try await read { try await self.store.records(serverConnectionID: key.serverConnectionID) }
            if !records.contains(where: { $0.key.libraryItemId == key.libraryItemId }) {
                refusedCovers[itemKey] = nil
            }
        } catch {
            logError("Couldn't read the downloads of an item", error)
        }
    }

    /// A cover-only record that completed after its local item was deleted
    /// (``DownloadUpdate/recordDiscarded(_:)``), while its item is held: its cover goes as a
    /// cancelled record's does (``cleanUp(after:removing:folder:cover:)``): to a pending episode
    /// record of the item, or a local item made since, or else it is removed. Then the record
    /// is reported removed.
    func discard(_ record: DownloadRecordDTO) async {
        await holdingItem(record.key) {
            let cover = record.parts.first { $0.kind == .cover }.map {
                CoverSource(
                    serverPath: $0.serverPath, relativePath: $0.destinationRelativePath, isStored: true,
                    updatedAt: record.media.coverUpdatedAt)
            }
            await cleanUp(
                after: record.key, removing: record.parts.map(\.destinationRelativePath), folder: nil, cover: cover)
            reportRemoved(record.id)
        }
    }

    private nonisolated func fileExists(_ relativePath: String) -> Bool {
        guard let url = try? locations.fileURL(forRelativePath: relativePath) else { return false }
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
}
