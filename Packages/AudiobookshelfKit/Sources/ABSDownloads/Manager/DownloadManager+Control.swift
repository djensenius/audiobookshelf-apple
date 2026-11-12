import ABSCore
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

    /// Resumes a paused or failed download: its record is queued again and its parts that
    /// haven't completed start, continuing from their resume data. Reported with
    /// ``DownloadManagerEvent/recordChanged(_:)``.
    ///
    /// - Returns: `false` when the record doesn't exist (it completed or was cancelled), or
    ///   isn't paused or failed. A queued or downloading one is left alone: the engine would
    ///   queue it while its transfers run on, and ``restartActiveTransfers()`` would then skip
    ///   them.
    /// - Throws: ``DownloadManagerError/storeFailure`` when it couldn't be read or saved.
    @discardableResult
    public func resume(recordID: UUID) async throws(DownloadManagerError) -> Bool {
        try await control(recordID, from: [.paused, .failed]) { try await $0.resume(recordID: $1) }
    }

    /// Retries a download that failed for good (or is paused), as ``resume(recordID:)`` does:
    /// its parts that haven't completed start again with a fresh retry budget.
    ///
    /// - Returns: `false` when the record doesn't exist (it completed or was cancelled), or
    ///   isn't paused or failed, as for ``resume(recordID:)``.
    /// - Throws: ``DownloadManagerError/storeFailure`` when it couldn't be read or saved.
    @discardableResult
    public func retry(recordID: UUID) async throws(DownloadManagerError) -> Bool {
        try await control(recordID, from: [.paused, .failed]) { try await $0.resume(recordID: $1) }
    }

    /// Pauses, then resumes, every `downloading` record, for a network policy that just got
    /// stricter: a transfer under way keeps the network access it started with, and resume data
    /// made under another access isn't used, so each transfer starts again under the new policy.
    /// Records that are queued, paused or failed are left alone, as is one paused or cancelled
    /// meanwhile; each restart is reported with ``DownloadManagerEvent/recordChanged(_:)``.
    ///
    /// The engine first reattaches to the transfers that survived a relaunch
    /// (``DownloadEngineControlling/attachSurvivingTransfers()``), so the pauses stop them too.
    ///
    /// A resume that fails is tried once more. If that fails too, the record is queued again,
    /// so it doesn't look paused by the user, and the engine starts it at its next activation.
    ///
    /// - Throws: ``DownloadManagerError/storeFailure`` at once when the engine has no session
    ///   (nothing is paused); otherwise the first one once every record was tried: the records
    ///   couldn't be read, or one couldn't be paused or resumed.
    public func restartActiveTransfers() async throws(DownloadManagerError) {
        guard await engine.attachSurvivingTransfers() else {
            Log.downloads.error("Couldn't restart downloads: the download session isn't available")
            throw .storeFailure
        }
        var firstError: DownloadManagerError?
        for record in try await read({ try await self.store.records(state: .downloading) }) {
            do throws(DownloadManagerError) {
                try await holdingItem(record.key) { () async throws(DownloadManagerError) in
                    try await restart(record.id)
                }
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    /// Pauses, then resumes, a record that is still `downloading`, for
    /// ``restartActiveTransfers()``; its caller holds the item. A sign-out's quiesce of its
    /// server that begins meanwhile passes over it while it is paused, so then it stays paused.
    private func restart(_ recordID: UUID) async throws(DownloadManagerError) {
        let generation = await engine.quiesceGeneration()
        // Paused or cancelled by the user meanwhile: not restarted.
        guard let record = try await read({ try await self.store.record(id: recordID) }),
            record.state == .downloading,
            try await read({ try await self.engine.pause(recordID: recordID) })
        else { return }
        var failure: DownloadManagerError?
        for _ in 0..<2 {
            do throws(DownloadManagerError) {
                _ = try await read {
                    try await self.engine.resume(recordID: recordID, unlessQuiescedSince: generation)
                }
                failure = nil
                break
            } catch {
                failure = error
            }
        }
        let connectionID = record.key.serverConnectionID
        if failure != nil, await !engine.hasQuiesced(connectionID: connectionID, since: generation) {
            // Not left paused, as if by the user.
            _ = try? await read {
                try await self.store.setState(.queued, forRecord: recordID, expecting: [.paused])
            }
        }
        await refresh(recordID, announce: true)
        if let failure { throw failure }
    }

    /// Cancels a download, while no enqueue, control or deletion of its item runs:
    ///
    /// 1. its record becomes `paused`, so no part starts again, and the engine stops its
    ///    transfers, deleting their resume data;
    /// 2. the record and its parts are deleted, unless every part has completed meanwhile
    ///    (``DownloadStore/deleteUnfinishedRecord(_:)``): then the engine is finalising it, so
    ///    its state is put back and reported with ``DownloadManagerEvent/recordChanged(_:)``,
    ///    and the result is `false`; ``DownloadManagerEvent/completed(recordID:itemID:key:)``
    ///    follows, and the user can delete the new local item instead;
    /// 3. ``DownloadManagerEvent/recordRemoved(recordID:)`` is reported;
    /// 4. if its cover part was the item's only cover stored or on its way, another record of
    ///    the item gets one, or else the item's local item gets it back (see
    ///    ``handOffCover(_:of:)``), unless the record only fetched that cover;
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
    /// - Throws: ``DownloadManagerError/storeFailure`` when it couldn't be read or deleted. When
    ///   the deletion itself fails, the record is left `paused` with its resume data deleted:
    ///   resumed, its transfers start over. Once it is deleted, the hand-off and file removal
    ///   are best effort: failures are logged and leave files for the sweep.
    @discardableResult
    public func cancel(recordID: UUID) async throws(DownloadManagerError) -> Bool {
        guard let first = try await read({ try await self.store.record(id: recordID) }) else { return false }
        return try await holdingItem(first.key) { () async throws(DownloadManagerError) -> Bool in
            // Read again: a hand-off from another cancel may have added a cover part.
            guard let record = try await read({ try await self.store.record(id: recordID) }),
                try await read({ try await self.store.setState(.paused, forRecord: recordID) })
            else { return false }
            await engine.stop(partIDs: record.parts.map(\.id), keepingResumeData: false)
            let deletion = try await read { try await self.store.deleteUnfinishedRecord(recordID) }
            guard case .deleted(let deleted) = deletion else {
                if case .complete = deletion {
                    _ = try? await read {
                        try await self.store.setState(record.state, forRecord: recordID, expecting: [.paused])
                    }
                    await refresh(recordID, announce: true)
                }
                return false
            }
            reportRemoved(recordID)
            for part in deleted.parts { locations.clearTransferMarker(partID: part.id) }
            let cover = deleted.parts.first { $0.kind == .cover }.map {
                CoverSource(
                    serverPath: $0.serverPath, relativePath: $0.destinationRelativePath,
                    isStored: $0.state == .completed, updatedAt: deleted.media.coverUpdatedAt,
                    restoresLocalItem: !deleted.isCoverOnly)
            }
            await cleanUp(
                after: deleted.key, removing: deleted.parts.map(\.destinationRelativePath), folder: nil, cover: cover)
            return true
        }
    }

    /// Runs an engine call on a record while its item is held, then reports the record. With
    /// `states`, only if the record is in one of them once the item is held.
    private func control(
        _ recordID: UUID, from states: [DownloadState]? = nil,
        _ call: (any DownloadEngineControlling, UUID) async throws -> Bool
    ) async throws(DownloadManagerError) -> Bool {
        guard let record = try await read({ try await self.store.record(id: recordID) }) else { return false }
        return try await holdingItem(record.key) { () async throws(DownloadManagerError) -> Bool in
            if let states {
                // Read again: another control may have changed its state.
                let current = try await read { try await self.store.record(id: recordID) }
                guard let current, states.contains(current.state) else { return false }
            }
            // A record gone meanwhile keeps its tracked key for its `recordComplete`.
            guard try await read({ try await call(self.engine, recordID) }) else { return false }
            await refresh(recordID, announce: true)
            return true
        }
    }
}
