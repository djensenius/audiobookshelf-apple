import ABSData
import Foundation

extension DownloadManager {
    // MARK: - Restoring a cover

    /// After the episode of `key` completed into the local item `itemID`, while its item is
    /// held: gives the local item a cover when it has none, so a cover the hand-off couldn't
    /// give to any record (``handOffCover(_:of:)``) isn't lost for good:
    /// 1. nothing happens while a queued or downloading record of the item will fetch one;
    /// 2. a cover another record has fetched, or one still on disk where the cover the hand-off
    ///    kept (``refusedCovers``) or the item's `cover.jpg` lies, is used as it is;
    /// 3. otherwise the cover the hand-off kept is fetched again (``refetchCover(_:for:)``).
    ///
    /// Without any of those, nothing is fetched: the item may have no cover on the server.
    /// Best effort: failures are logged.
    func restoreCover(after key: MediaKey, itemID: UUID) async {
        let itemKey = MediaKey(serverConnectionID: key.serverConnectionID, libraryItemId: key.libraryItemId)
        let refused = refusedCovers.removeValue(forKey: itemKey)
        do throws(DownloadManagerError) {
            guard let item = try await read({ try await self.localItems.item(id: itemID) }),
                item.coverRelativePath == nil
            else { return }
            let existing = try await existingCover(for: itemKey, localItem: item)
            guard existing.pendingPath == nil else { return }
            let updatedAt = refused?.updatedAt ?? item.coverUpdatedAt
            if let completed = existing.completed {
                try await adoptCover(completed.destinationRelativePath, updatedAt: updatedAt, for: item)
                return
            }
            let layoutPath = try? DownloadLayout(
                connectionID: item.serverConnectionID, libraryItemID: item.libraryItemId, locations: locations
            ).coverPath()
            if let stored = [refused?.relativePath, layoutPath].compactMap({ $0 }).first(where: fileExists) {
                try await adoptCover(stored, updatedAt: updatedAt, for: item)
            } else if let refused {
                try await refetchCover(refused, for: item)
            }
        } catch {
            logError("Couldn't restore a downloaded item's cover", error)
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

    /// Saves and starts a cover-only record (``DownloadRecordDTO/isCoverOnly``) under the
    /// item-level key of `item`, which fetches `cover` again; once complete, the engine sets it
    /// as the local item's cover. Nothing is saved while the item has a record under that key
    /// (a refetch already queued, paused or failed) or its connection is signed out or
    /// disconnected (``DownloadStore/insertRecordIfSignedIn(_:now:)``). Its caller holds the
    /// item. Like any record, it can be paused, resumed or cancelled, and is reported with
    /// ``DownloadManagerEvent/recordChanged(_:)``; once complete it is reported with
    /// ``DownloadManagerEvent/recordRemoved(recordID:)``, as it downloaded no media.
    func refetchCover(_ cover: CoverSource, for item: LocalLibraryItemDTO) async throws(DownloadManagerError) {
        let part = DownloadPartDTO(
            kind: .cover, serverPath: cover.serverPath, filename: DownloadLayout.coverFilename, mimeType: "image/jpeg",
            expectedBytes: 0, bytesWritten: 0, destinationRelativePath: cover.relativePath, state: .queued)
        let plan = DownloadRecordDTO(
            key: MediaKey(serverConnectionID: item.serverConnectionID, libraryItemId: item.libraryItemId),
            mediaType: item.mediaType, title: item.title, relativeDirectory: item.relativeDirectory,
            media: LocalMediaSnapshot(metadata: item.media.metadata, coverUpdatedAt: cover.updatedAt), parts: [part])
        guard let record = try await read({ try await self.store.insertRecordIfSignedIn(plan) }) else { return }
        track(record)
        emit(.recordChanged(record))
        await engine.start(partIDs: [part.id])
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
