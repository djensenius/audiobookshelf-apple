import ABSData
import Foundation

extension DownloadManager {
    // MARK: - Control

    /// Pauses a download: its record becomes `paused` and the engine stops its transfers,
    /// keeping their resume data. Reported with ``DownloadManagerEvent/recordChanged(_:)``.
    ///
    /// - Returns: `false` when the record doesn't exist: it completed or was cancelled.
    /// - Throws: ``DownloadManagerError/storeFailure`` when it couldn't be read or saved.
    @discardableResult
    public func pause(recordID: UUID) async throws(DownloadManagerError) -> Bool {
        try await control(recordID) { try await $0.pause(recordID: $1) }
    }

    /// Resumes a paused download: its record is queued again and its parts that haven't
    /// completed start, continuing from their resume data. Reported with
    /// ``DownloadManagerEvent/recordChanged(_:)``.
    ///
    /// - Returns: `false` when the record doesn't exist: it completed or was cancelled.
    /// - Throws: ``DownloadManagerError/storeFailure`` when it couldn't be read or saved.
    @discardableResult
    public func resume(recordID: UUID) async throws(DownloadManagerError) -> Bool {
        try await control(recordID) { try await $0.resume(recordID: $1) }
    }

    /// Retries a download that failed for good, as ``resume(recordID:)`` does: its parts that
    /// haven't completed start again with a fresh retry budget.
    ///
    /// - Returns: `false` when the record doesn't exist: it completed or was cancelled.
    /// - Throws: ``DownloadManagerError/storeFailure`` when it couldn't be read or saved.
    @discardableResult
    public func retry(recordID: UUID) async throws(DownloadManagerError) -> Bool {
        try await control(recordID) { try await $0.resume(recordID: $1) }
    }

    /// Pauses, then resumes, every `downloading` record, for a network policy that just got
    /// stricter: a transfer under way keeps the network access it started with, and resume data
    /// made under another access isn't used, so each transfer starts again under the new policy.
    /// Records that are queued, paused or failed are left alone; each restart is reported with
    /// ``DownloadManagerEvent/recordChanged(_:)``.
    ///
    /// - Throws: ``DownloadManagerError/storeFailure`` at the first record that couldn't be read
    ///   or saved; the records after it aren't restarted.
    public func restartActiveTransfers() async throws(DownloadManagerError) {
        for record in try await read({ try await self.store.records(state: .downloading) }) {
            try await holdingItem(record.key) { () async throws(DownloadManagerError) in
                // Paused or cancelled by the user meanwhile: not restarted.
                guard try await read({ try await self.store.record(id: record.id) })?.state == .downloading,
                    try await read({ try await self.engine.pause(recordID: record.id) })
                else { return }
                _ = try await read { try await self.engine.resume(recordID: record.id) }
                await refresh(record.id, announce: true)
            }
        }
    }

    /// Cancels a download, while no enqueue, control or deletion of its item runs:
    ///
    /// 1. its record becomes `paused`, so no part starts again, and the engine stops its
    ///    transfers, deleting their resume data;
    /// 2. the record and its parts are deleted, unless every part has completed meanwhile
    ///    (``DownloadStore/deleteUnfinishedRecord(_:)``): then the engine is finalising it, and
    ///    the result is `false`; ``DownloadManagerEvent/completed(recordID:itemID:key:)``
    ///    follows, and the user can delete the new local item instead;
    /// 3. ``DownloadManagerEvent/recordRemoved(recordID:)`` is reported;
    /// 4. if its cover part was the item's only cover stored or on its way, another record of
    ///    the item gets one (see ``handOffCover(_:of:)``);
    /// 5. its files that no local item or other record uses are removed, with folders left
    ///    empty, so a shared podcast `cover.jpg` stays while anything uses it.
    ///
    /// A part that is settling (its file being moved into place, or it failing for good) isn't
    /// stopped. Once the record is deleted, its completion finds no part and does nothing, so
    /// the download can't come back; but its file can land after step 5, and a part failing for
    /// good can seal its resume data after step 1. The `DownloadJanitor` (#192) sweeps both:
    /// files no local item or record references, and blobs whose part is gone.
    ///
    /// - Returns: whether the record was deleted.
    /// - Throws: ``DownloadManagerError/storeFailure`` when it couldn't be read or deleted. Once
    ///   it is deleted, the hand-off and file removal are best effort: failures are logged and
    ///   leave files for the sweep.
    @discardableResult
    public func cancel(recordID: UUID) async throws(DownloadManagerError) -> Bool {
        guard let first = try await read({ try await self.store.record(id: recordID) }) else { return false }
        return try await holdingItem(first.key) { () async throws(DownloadManagerError) -> Bool in
            // Read again: a hand-off from another cancel may have added a cover part.
            guard let record = try await read({ try await self.store.record(id: recordID) }),
                try await read({ try await self.store.setState(.paused, forRecord: recordID) })
            else { return false }
            await engine.stop(partIDs: record.parts.map(\.id), keepingResumeData: false)
            guard case .deleted(let deleted) = try await read({ try await self.store.deleteUnfinishedRecord(recordID) })
            else { return false }
            forget(recordID)
            emit(.recordRemoved(recordID: recordID))
            for part in deleted.parts { locations.clearTransferMarker(partID: part.id) }
            let cover = deleted.parts.first { $0.kind == .cover }.map {
                CoverSource(
                    serverPath: $0.serverPath, relativePath: $0.destinationRelativePath,
                    isStored: $0.state == .completed, updatedAt: deleted.media.coverUpdatedAt)
            }
            await cleanUp(
                after: deleted.key, removing: deleted.parts.map(\.destinationRelativePath), folder: nil, cover: cover)
            return true
        }
    }

    /// Runs an engine call on a record while its item is held, then reports the record.
    private func control(
        _ recordID: UUID, _ call: (any DownloadEngineControlling, UUID) async throws -> Bool
    ) async throws(DownloadManagerError) -> Bool {
        guard let record = try await read({ try await self.store.record(id: recordID) }) else { return false }
        return try await holdingItem(record.key) { () async throws(DownloadManagerError) -> Bool in
            // A record gone meanwhile keeps its tracked key for its `recordComplete`.
            guard try await read({ try await call(self.engine, recordID) }) else { return false }
            await refresh(recordID, announce: true)
            return true
        }
    }
}
