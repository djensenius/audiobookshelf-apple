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
    /// is dropped once it is used, or a record will fetch it; a refetch that couldn't be saved
    /// or resumed (signed out) or a failed read keeps it for the next completion. Best effort:
    /// failures are logged.
    func restoreCover(after key: MediaKey, itemID: UUID) async {
        let itemKey = MediaKey(serverConnectionID: key.serverConnectionID, libraryItemId: key.libraryItemId)
        do throws(DownloadManagerError) {
            if try await restoreCover(of: itemID, itemKey: itemKey, refused: refusedCovers[itemKey]) {
                refusedCovers[itemKey] = nil
            }
        } catch {
            logError("Couldn't restore a downloaded item's cover", error)
        }
    }

    /// - Returns: whether the kept cover is done with: `false` when a refetch was needed but
    ///   couldn't be saved or resumed.
    private func restoreCover(
        of itemID: UUID, itemKey: MediaKey, refused: CoverSource?
    ) async throws(DownloadManagerError) -> Bool {
        guard let item = try await read({ try await self.localItems.item(id: itemID) }) else { return true }
        guard item.coverRelativePath == nil else {
            try await dropStalledRefetch(itemKey)
            return true
        }
        let existing = try await existingCover(for: itemKey, localItem: item)
        guard existing.pendingPath == nil else { return true }
        let updatedAt = refused?.updatedAt ?? item.coverUpdatedAt
        if let completed = existing.completed {
            // Dated by the record that fetched it.
            try await adoptCover(
                completed.destinationRelativePath, updatedAt: existing.completedUpdatedAt ?? updatedAt, for: item)
            return true
        }
        let layoutPath = try? DownloadLayout(
            connectionID: item.serverConnectionID, libraryItemID: item.libraryItemId, locations: locations
        ).coverPath()
        if let stored = [refused?.relativePath, layoutPath].compactMap({ $0 }).first(where: fileExists) {
            try await adoptCover(stored, updatedAt: updatedAt, for: item)
            return true
        }
        return try await refetchCover(refused, for: item)
    }

    /// Makes the file at `path`, on disk, the local item's cover, unless it got one meanwhile:
    /// the engine finalises downloads without holding the item. Then, as the item has a cover,
    /// a paused or failed refetch of it is deleted (``dropStalledRefetch(_:)``). Called while
    /// the item is held.
    func adoptCover(
        _ path: String, updatedAt: Date?, for item: LocalLibraryItemDTO
    ) async throws(DownloadManagerError) {
        _ = try await read {
            try await self.localItems.setCoverIfMissing(itemID: item.id, relativePath: path, updatedAt: updatedAt)
        }
        try await dropStalledRefetch(
            MediaKey(serverConnectionID: item.serverConnectionID, libraryItemId: item.libraryItemId))
    }

    /// Fetches the cover of `item` again, under its item-level key, while its caller holds the
    /// item:
    /// - a cover-only record (``DownloadRecordDTO/isCoverOnly``) already there that is paused or
    ///   failed is resumed: it is hidden from the user, who can't; a queued or downloading one
    ///   is left alone. Like the insert below, nothing is resumed while the connection is signed
    ///   out or disconnected (``DownloadStore/isSignedIn(serverConnectionID:)``);
    /// - otherwise, with `cover`, a new cover-only record that fetches it is saved and started.
    ///   Nothing is saved while the connection is signed out or disconnected, or the key is
    ///   taken (``DownloadStore/insertRecordIfSignedIn(_:now:)``). Its file gets a name of its
    ///   own beside `cover`'s, so it never replaces a cover another record fetched meanwhile;
    ///   the engine makes it the item's cover only if the item still has none, and the manager
    ///   removes it otherwise (``complete(_:as:)``).
    ///
    /// Once complete, the engine sets the cover as the local item's. Like any record, it is
    /// reported with ``DownloadManagerEvent/recordChanged(_:)``; once complete with
    /// ``DownloadManagerEvent/recordRemoved(recordID:)``, as it downloaded no media.
    ///
    /// - Returns: whether a refetch is on its way: `false` when none could be saved or resumed.
    @discardableResult
    func refetchCover(
        _ cover: CoverSource?, for item: LocalLibraryItemDTO
    ) async throws(DownloadManagerError) -> Bool {
        let key = MediaKey(serverConnectionID: item.serverConnectionID, libraryItemId: item.libraryItemId)
        if let current = try await read({ try await self.store.record(key: key) }) {
            guard current.isCoverOnly, current.state == .paused || current.state == .failed else { return true }
            guard try await read({ try await self.store.isSignedIn(serverConnectionID: key.serverConnectionID) }),
                try await read({ try await self.engine.resume(recordID: current.id) })
            else { return false }
            await refresh(current.id, announce: true)
            return true
        }
        guard let cover else { return false }
        let partID = UUID()
        let folder = (cover.relativePath as NSString).deletingLastPathComponent
        let name = "cover-\(partID.uuidString.lowercased()).jpg"
        let part = DownloadPartDTO(
            id: partID, kind: .cover, serverPath: cover.serverPath, filename: DownloadLayout.coverFilename,
            mimeType: "image/jpeg", expectedBytes: 0, bytesWritten: 0,
            destinationRelativePath: folder.isEmpty ? name : "\(folder)/\(name)", state: .queued)
        let plan = DownloadRecordDTO(
            key: key, mediaType: item.mediaType, title: item.title, relativeDirectory: item.relativeDirectory,
            media: LocalMediaSnapshot(metadata: item.media.metadata, coverUpdatedAt: cover.updatedAt), parts: [part])
        guard let record = try await read({ try await self.store.insertRecordIfSignedIn(plan) }) else { return false }
        track(record)
        emit(.recordChanged(record))
        await engine.start(partIDs: [part.id])
        return true
    }

    /// A cover-only record whose fetch failed for good, while its item is held: deleted and
    /// reported removed, as the user, who doesn't see it, can't retry it, and while it stays it
    /// keeps its connection's records from being purged. Its cover is kept in
    /// ``refusedCovers``, so the item's next episode completion fetches it again. Best effort:
    /// failures are logged, and leave the failed record for ``refetchCover(_:for:)`` to resume.
    /// Also run at ``start()``, for a failure saved before the process ended. A refetch that
    /// failed as its file was too large (``DownloadFailureCode/tooLarge``) isn't kept to try again.
    func dropFailedRefetch(_ recordID: UUID, code: DownloadFailureCode? = nil) async {
        do throws(DownloadManagerError) {
            guard let first = try await read({ try await self.store.record(id: recordID) }) else { return }
            try await holdingItem(first.key) { () async throws(DownloadManagerError) in
                // Read again: it may have been resumed or cancelled meanwhile.
                guard let record = try await read({ try await self.store.record(id: recordID) }),
                    record.isCoverOnly, record.state == .failed,
                    let deleted = try await deleteRefetch(record)
                else { return }
                if let part = deleted.parts.first, code != .tooLarge {
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

    /// While the item of `itemKey` is held, after its local item was deleted: cancels its
    /// cover-only record, as ``cancel(recordID:)`` cancels an episode (paused, stopped without
    /// keeping resume data, deleted, its transfer markers cleared), so the cover isn't fetched
    /// for an item that is gone. One that has completed meanwhile is left to the engine, which
    /// discards it (``DownloadUpdate/recordDiscarded(_:)``).
    /// - Returns: the paths of the cancelled record's files, for the caller to remove, and its
    ///   cover, for the caller to hand on (``handOffCover(_:of:)``): an episode queued while it
    ///   ran was planned without a cover part, as it shared this one.
    func cancelRefetch(
        of itemKey: MediaKey
    ) async throws(DownloadManagerError) -> (paths: [String], cover: CoverSource?) {
        guard let record = try await read({ try await self.store.record(key: itemKey) }), record.isCoverOnly,
            try await read({ try await self.store.setState(.paused, forRecord: record.id) })
        else { return ([], nil) }
        guard let deleted = try await deleteRefetch(record) else {
            _ = try? await read {
                try await self.store.setState(record.state, forRecord: record.id, expecting: [.paused])
            }
            await refresh(record.id, announce: true)
            return ([], nil)
        }
        let cover = deleted.parts.first { $0.kind == .cover }.map {
            CoverSource(
                serverPath: $0.serverPath, relativePath: $0.destinationRelativePath,
                isStored: $0.state == .completed, updatedAt: deleted.media.coverUpdatedAt)
        }
        return (deleted.parts.map(\.destinationRelativePath), cover)
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
