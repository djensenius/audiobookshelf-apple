import ABSCore
import ABSData
import Foundation

/// Brings the local playback database in line with a progress action the server accepted, so
/// the syncer's durable queue (`ProgressSyncer.drainPendingProgress`) can't undo it with an
/// older local value.
///
/// ``ProgressItemActions`` calls it only after the server call succeeded and the optimistic
/// value was committed: never before the request, and never for an action that failed or was
/// rolled back. A thrown error is logged there and not rethrown, because the server change
/// already happened.
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
/// Each action reads and writes the row in separate store calls; a playback write in between
/// may be overwritten or follow the edit, which a playing session repeats anyway.
public struct LocalProgressItemActionSync: ItemActionLocalSync {
    private let store: LocalProgressStore
    private let connectionID: UUID

    public init(store: LocalProgressStore, connectionID: UUID) {
        self.store = store
        self.connectionID = connectionID
    }

    public func didMarkFinished(_ target: ItemActionTarget) async throws {
        let key = key(for: target)
        guard try await store.progress(for: key) != nil else { return }
        try await store.recordEdit(ProgressEdit(isFinished: true), for: key)
    }

    public func didMarkNotFinished(_ target: ItemActionTarget) async throws {
        let key = key(for: target)
        guard let row = try await store.progress(for: key) else { return }
        let audio = ProgressEdit.Audio(currentTime: 0, duration: row.duration, progress: 0)
        try await store.recordEdit(ProgressEdit(audio: audio, isFinished: false), for: key)
    }

    public func didDiscard(_ target: ItemActionTarget) async throws {
        try await store.deleteProgress(for: key(for: target))
    }

    private func key(for target: ItemActionTarget) -> MediaKey {
        MediaKey(serverConnectionID: connectionID, libraryItemId: target.libraryItemID, episodeId: target.episodeID)
    }
}
