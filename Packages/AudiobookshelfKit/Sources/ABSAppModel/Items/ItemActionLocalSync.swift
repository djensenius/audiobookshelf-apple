import ABSCore
import ABSData
import ABSPlayback
import Foundation

/// Brings the local playback database in line with a progress action the server accepted, so
/// the syncer's durable queue (`ProgressSyncer.drainPendingProgress`) can't undo it with an
/// older local value.
///
/// ``ProgressItemActions`` calls it only after the server call succeeded, and the optimistic
/// value was committed unless the session ended meanwhile: never before the request, and never
/// for an action that failed or was rolled back. A thrown error is logged there and not
/// rethrown, because the server change already happened.
public protocol ItemActionLocalSync: Sendable {
    func didMarkFinished(_ target: ItemActionTarget) async throws
    func didMarkNotFinished(_ target: ItemActionTarget) async throws
    func didDiscard(_ target: ItemActionTarget) async throws
}

/// ``ItemActionLocalSync`` for one account's rows in ``LocalProgressStore``.
///
/// - Mark as finished records `isFinished` on an existing row only (nothing local to undo it
///   otherwise). The drain sends the audio group before the finished group, so a dirty position
///   can't un-finish the item on the server afterwards.
/// - Mark as not finished resets the row's position to 0 with `isFinished` false, so an old
///   near-the-end position can't finish the item again; also only on an existing row.
/// - Discard deletes the row (legacy `removeLocalMediaProgress`), so its dirty values can't
///   create the progress again.
///
/// Each action first supersedes the media's playback positions reserved so far
/// (``LocalProgressStore/supersedePlaybackPositions(for:)``), row or not, so a closed session's
/// position whose save failed and is retried later can't undo the action. The action's media
/// lease keeps new playback of the media from reserving one until the edit is done. It also
/// clears the account's last-played record (`lastPlayed`) when it's the media's: its dated
/// position predates the action, and with the progress discarded nothing newer would outweigh
/// it, so a replay would resume there. A record for other media stays.
///
/// Each action reads and writes the row in separate store calls; a playback write in between
/// may be overwritten or follow the edit, which a playing session repeats anyway.
public struct LocalProgressItemActionSync: ItemActionLocalSync {
    /// The writer it edits: the one the account's `ProgressSyncer` writes through.
    public let store: LocalProgressStore
    public let connectionID: UUID
    /// The account's last-played store (`PlaybackScope.lastPlayedStore(for:defaults:)`); `nil`
    /// leaves the record alone.
    public let lastPlayed: (@MainActor @Sendable () -> any LastPlayedStoring)?

    public init(
        store: LocalProgressStore, connectionID: UUID,
        lastPlayed: (@MainActor @Sendable () -> any LastPlayedStoring)? = nil
    ) {
        self.store = store
        self.connectionID = connectionID
        self.lastPlayed = lastPlayed
    }

    public func didMarkFinished(_ target: ItemActionTarget) async throws {
        let key = key(for: target)
        await supersede(key)
        guard try await store.progress(for: key) != nil else { return }
        try await store.recordEdit(ProgressEdit(isFinished: true), for: key)
    }

    public func didMarkNotFinished(_ target: ItemActionTarget) async throws {
        let key = key(for: target)
        await supersede(key)
        guard let row = try await store.progress(for: key) else { return }
        let audio = ProgressEdit.Audio(currentTime: 0, duration: row.duration, progress: 0)
        try await store.recordEdit(ProgressEdit(audio: audio, isFinished: false), for: key)
    }

    public func didDiscard(_ target: ItemActionTarget) async throws {
        let key = key(for: target)
        await supersede(key)
        try await store.deleteProgress(for: key)
    }

    /// Supersedes the media's reserved playback positions and its last-played record.
    private func supersede(_ key: MediaKey) async {
        await store.supersedePlaybackPositions(for: key)
        await forgetLastPlayed(key)
    }

    @MainActor private func forgetLastPlayed(_ key: MediaKey) {
        guard let records = lastPlayed?(), records.load()?.key == key else { return }
        records.clear()
    }

    private func key(for target: ItemActionTarget) -> MediaKey {
        MediaKey(serverConnectionID: connectionID, libraryItemId: target.libraryItemID, episodeId: target.episodeID)
    }
}
