import ABSAPI
import ABSCore
import ABSPlayback
import Foundation

/// The actions on a library item that change the user's progress. Play, add to playlist and
/// share are not here: the caller handles them (play needs the playback coordinator).
///
/// There is no environment key in the package: the app shell or the feature declares one whose
/// default is ``NoOpItemActions`` (so previews and tests need no setup) and injects
/// ``ProgressItemActions`` for the signed-in account.
@MainActor
public protocol ItemActionPerforming: Sendable {
    /// Marks the item or episode finished.
    func markFinished(_ target: ItemActionTarget) async throws
    /// Marks the item or episode not finished; the server resets finished progress to the start.
    func markNotFinished(_ target: ItemActionTarget) async throws
    /// Hides the item or episode from Continue Listening without touching its progress.
    func hideFromContinueListening(_ target: ItemActionTarget) async throws
    /// Deletes the user's progress on the item or episode; does nothing when there is none.
    func discardProgress(_ target: ItemActionTarget) async throws
}

/// The item or episode an action applies to.
public struct ItemActionTarget: Sendable, Hashable {
    public var libraryItemID: String
    public var episodeID: String?
    /// Seconds, when known: lets "finished" show a full bar for an item with no progress yet.
    public var duration: Double?

    public init(libraryItemID: String, episodeID: String? = nil, duration: Double? = nil) {
        self.libraryItemID = libraryItemID
        self.episodeID = episodeID
        self.duration = duration
    }

    var key: String { MediaProgress.key(libraryItemID: libraryItemID, episodeID: episodeID) }
}

/// Does nothing; the default for an environment value.
public struct NoOpItemActions: ItemActionPerforming {
    /// Nonisolated, so it can be an environment key's default value.
    nonisolated public init() {}
    public func markFinished(_ target: ItemActionTarget) async throws {}
    public func markNotFinished(_ target: ItemActionTarget) async throws {}
    public func hideFromContinueListening(_ target: ItemActionTarget) async throws {}
    public func discardProgress(_ target: ItemActionTarget) async throws {}
}

/// Why ``ProgressItemActions`` refused an action.
public enum ItemActionError: Error, Equatable {
    /// The item or episode is the player's: its session would write its own position back over the
    /// change, so marking it finished or not finished, or discarding its progress, waits until the
    /// player is closed.
    case itemInPlayer
}

/// Sends a progress change (`PATCH /api/me/progress/:item[/:episode]`) or deletion
/// (`DELETE /api/me/progress/:id`); `APIClient` conforms.
public protocol ProgressWriting: Sendable {
    func writeProgress(itemID: String, episodeID: String?, update: MediaProgressUpdate) async throws
    /// The server's ID of the user's progress on the item or episode
    /// (`GET /api/me/progress/:item[/:episode]`), or `nil` when the server has none.
    func progressID(itemID: String, episodeID: String?) async throws -> String?
    /// Deletes one progress by its own ID (``MediaProgress/id``), not the item's.
    func deleteProgress(id: String) async throws
}

extension APIClient: ProgressWriting {
    public func writeProgress(itemID: String, episodeID: String?, update: MediaProgressUpdate) async throws {
        _ = try await send(ProgressEndpoints.update(itemID: itemID, episodeID: episodeID, update))
    }

    public func progressID(itemID: String, episodeID: String?) async throws -> String? {
        try await mediaProgress(itemID: itemID, episodeID: episodeID)?.id
    }

    public func deleteProgress(id: String) async throws {
        _ = try await send(ProgressEndpoints.delete(id: id))
    }
}

/// The default actions: change the ``ProgressCache`` right away, send the PATCH, and put the
/// previous progress back if it fails (the error is rethrown for the caller to report).
///
/// Rules:
/// - Actions on the same item or episode run one after the other, in the order they were called:
///   the second starts (and reads the progress it changes) after the first's request finished and,
///   if it failed, rolled back. Actions on other keys don't wait.
/// - A rollback restores the previous progress only while the cache still holds the optimistic
///   value (``ProgressCache/rollback(_:to:)``): an update that arrived meanwhile (socket, local
///   playback) is newer and stays.
/// - Discarding removes the progress from the cache, asks the server for its progress ID (a
///   cached entry may be an optimistic one with a local ID), and deletes that. Without cached
///   progress it sends nothing; without server progress it sends no DELETE. A DELETE answered
///   404 counts as done: the progress is already gone.
/// - An action runs to completion even if its caller is cancelled, so the cache and the server
///   don't end up disagreeing about a half-done action.
/// - Optimistic ordering is tracked separately from server timestamps. A full progress seed
///   requested after a successful action reconciles its authoritative row, even with clock skew.
/// - The per-key queue belongs to this instance: inject one instance per account and share it
///   between screens and windows (``LibraryStore/itemActions(for:)``, which the app shell
///   injects), or actions from two instances on the same key can interleave.
/// - After the server accepted marking finished or not finished, or discarding, and the change
///   was committed, `localSync` (``ItemActionLocalSync``) updates the local playback database,
///   still in the key's queue, so the syncer's pending values can't undo the change. It isn't
///   called for a failed or rolled-back action, or for hiding; its errors are logged, not thrown.
///   It also runs for a request the server accepted after the session ended (sign-out or account
///   switch), since it's bound to the account's connection; the action then leaves the ended
///   session's cache alone and throws `CancellationError`.
/// - Marking finished or not finished and discarding are refused with
///   ``ItemActionError/itemInPlayer`` while `isInPlayer` says the item or episode is in the player
///   (playing, paused, or restored and not loaded yet), checked when the action's turn in the queue
///   comes and before anything changes: the player's session keeps writing its own position
///   locally and to the server, so it could undo the change. Closing the player first is the
///   user's choice; hiding only touches Continue Listening and isn't refused.
/// - Before that check, these actions take `lease` for the item or episode (``MediaLeases``,
///   shared with playback), which waits for a closed session's final `/close` and position write
///   to settle, and hold it through the server request and the local sync, so a playback start
///   of the same media waits for the action instead of starting from the old position.
@MainActor
public final class ProgressItemActions: ItemActionPerforming {
    private struct Tail {
        let ticket: Int
        let task: Task<Result<Void, any Error>, Never>
    }

    private let cache: ProgressCache
    private let writer: any ProgressWriting
    /// Updates the local playback database after an accepted action; `nil` updates nothing.
    public let localSync: (any ItemActionLocalSync)?
    private let isInPlayer: @MainActor (ItemActionTarget) -> Bool
    private let lease: @MainActor (ItemActionTarget) async -> MediaLease?
    private let now: @Sendable () -> Date
    private let sessionToken: ProgressCache.SessionToken
    private var tails: [String: Tail] = [:]
    /// A predecessor's actions still pending per key; see ``continueQueue(of:)``.
    private var inheritedTails: [String: Task<Result<Void, any Error>, Never>] = [:]
    private var tickets = 0

    public init(
        cache: ProgressCache, writer: any ProgressWriting, localSync: (any ItemActionLocalSync)? = nil,
        isInPlayer: @escaping @MainActor (ItemActionTarget) -> Bool = { _ in false },
        lease: @escaping @MainActor (ItemActionTarget) async -> MediaLease? = { _ in nil },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.lease = lease
        self.cache = cache
        self.writer = writer
        self.localSync = localSync
        self.isInPlayer = isInPlayer
        self.now = now
        self.sessionToken = cache.sessionToken()
    }

    /// Whether the progress session the actions were built in is still the cache's: `false`
    /// after a ``ProgressCache/clear()`` (sign-out, account switch, or a failed switch's restart).
    var isCurrentSession: Bool { cache.isCurrent(sessionToken) }

    /// Orders this instance's actions after `predecessor`'s still pending ones on the same key,
    /// so a write from the session it replaces can't land after a newer one. A stale instance
    /// queues nothing new (``enqueue(_:operation:)`` rejects it), so its tails are final.
    func continueQueue(of predecessor: ProgressItemActions) {
        // The predecessor's own tail on a key already chained on what it inherited for the key;
        // keys it never acted on keep the inherited tail, across any number of restarts.
        inheritedTails = predecessor.inheritedTails.merging(predecessor.tails.mapValues(\.task)) { $1 }
    }

    public func markFinished(_ target: ItemActionTarget) async throws {
        try await run(target, update: .finished(true, at: now()), local: { try await $0.didMarkFinished(target) }) {
            existing, date in
            Self.finished(target, existing: existing, at: date)
        }
    }

    public func markNotFinished(_ target: ItemActionTarget) async throws {
        try await run(target, update: .finished(false), local: { try await $0.didMarkNotFinished(target) }) {
            existing, _ in
            guard var progress = existing, progress.isFinished else { return nil }
            progress.isFinished = false
            progress.progress = 0
            progress.currentTime = 0
            progress.finishedAt = nil
            return progress
        }
    }

    public func hideFromContinueListening(_ target: ItemActionTarget) async throws {
        try await run(target, update: .hideFromContinueListening(true)) { existing, _ in
            guard var progress = existing else { return nil }
            progress.hideFromContinueListening = true
            return progress
        }
    }

    public func discardProgress(_ target: ItemActionTarget) async throws {
        try await enqueue(target) { session in
            let lease = try await self.claim(target)
            defer { lease?.release() }
            guard try await self.discard(target, session: session) else { return }
            await self.syncLocally { try await $0.didDiscard(target) }
            guard self.cache.isCurrent(session) else { throw CancellationError() }
        }
    }

    // MARK: Optimistic values

    private static func finished(_ target: ItemActionTarget, existing: MediaProgress?, at date: Date) -> MediaProgress {
        let milliseconds = Int((date.timeIntervalSince1970 * 1000).rounded())
        var progress =
            existing
            ?? MediaProgress(
                id: target.key, libraryItemId: target.libraryItemID, episodeId: target.episodeID,
                duration: target.duration ?? 0)
        progress.isFinished = true
        progress.progress = 1
        progress.currentTime = progress.duration
        progress.finishedAt = milliseconds
        return progress
    }

    // MARK: Running

    /// The local database's part of an action, run after the server accepted it.
    private typealias LocalUpdate = @Sendable (any ItemActionLocalSync) async throws -> Void

    private func run(
        _ target: ItemActionTarget, update: MediaProgressUpdate, local: LocalUpdate? = nil,
        optimistic: @escaping @MainActor (MediaProgress?, Date) -> MediaProgress?
    ) async throws {
        try await enqueue(target) { session in
            // An action with a local part changes the position the player's session writes.
            let lease = local != nil ? try await self.claim(target) : nil
            defer { lease?.release() }
            try await self.perform(target, update: update, optimistic: optimistic, session: session)
            await self.syncLocally(local)
            guard self.cache.isCurrent(session) else { throw CancellationError() }
        }
    }

    /// Takes the item's lease (after its closing sessions settled), then refuses the player's item.
    private func claim(_ target: ItemActionTarget) async throws -> MediaLease? {
        let lease = await lease(target)
        guard !isInPlayer(target) else {
            lease?.release()
            throw ItemActionError.itemInPlayer
        }
        return lease
    }

    /// Runs `local` on ``localSync``, logging a failure: the server already has the change.
    private func syncLocally(_ local: LocalUpdate?) async {
        guard let local, let localSync else { return }
        do {
            try await local(localSync)
        } catch {
            Log.data.error(
                "Couldn't update local progress after an item action: \(String(describing: error), privacy: .public)")
        }
    }

    /// Runs `operation` after the actions already queued for `target`'s key.
    private func enqueue(
        _ target: ItemActionTarget,
        operation: @escaping @MainActor (ProgressCache.SessionToken) async throws -> Void
    ) async throws {
        let actionSession = cache.sessionToken()
        guard actionSession == sessionToken else { throw CancellationError() }
        let key = target.key
        // Later actions on the key chain on the first one, which waited for the predecessor's.
        let previous = tails[key]?.task ?? inheritedTails.removeValue(forKey: key)
        tickets += 1
        let ticket = tickets
        let task = Task<Result<Void, any Error>, Never> { @MainActor in
            _ = await previous?.value
            do {
                try await operation(actionSession)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        tails[key] = Tail(ticket: ticket, task: task)
        let result = await task.value
        if tails[key]?.ticket == ticket { tails[key] = nil }
        try result.get()
    }

    private func perform(
        _ target: ItemActionTarget, update: MediaProgressUpdate,
        optimistic: (MediaProgress?, Date) -> MediaProgress?, session: ProgressCache.SessionToken
    ) async throws {
        guard cache.isCurrent(session) else { throw CancellationError() }
        let before = cache.progress(libraryItemID: target.libraryItemID, episodeID: target.episodeID)
        let applied = optimistic(before, now()).flatMap { cache.applyOptimistic($0, token: session) }
        guard cache.isCurrent(session) else { throw CancellationError() }
        do {
            try await writer.writeProgress(
                itemID: target.libraryItemID, episodeID: target.episodeID, update: update)
        } catch {
            guard cache.isCurrent(session) else { throw CancellationError() }
            if let applied { cache.rollbackOptimistic(applied, to: before, token: session) }
            throw error
        }
        // Accepted: an ended session's cache isn't touched, but the caller still syncs locally.
        if let applied, cache.isCurrent(session) { cache.commitOptimistic(applied, token: session) }
    }

    /// Returns whether the server's progress is gone, also once the session ended during the
    /// DELETE; `false` when there was nothing to discard.
    private func discard(_ target: ItemActionTarget, session: ProgressCache.SessionToken) async throws -> Bool {
        guard cache.isCurrent(session) else { throw CancellationError() }
        guard let before = cache.progress(libraryItemID: target.libraryItemID, episodeID: target.episodeID) else {
            return false
        }
        guard
            let removal = cache.applyOptimisticRemoval(
                libraryItemID: target.libraryItemID, episodeID: target.episodeID, token: session)
        else { throw CancellationError() }
        do {
            if let id = try await writer.progressID(itemID: target.libraryItemID, episodeID: target.episodeID) {
                // Signed out or switched account during the lookup: don't delete through the old writer.
                guard cache.isCurrent(session) else { throw CancellationError() }
                do {
                    try await writer.deleteProgress(id: id)
                } catch APIError.notFound {
                    // Deleted already, for example from another device.
                }
            }
        } catch {
            guard cache.isCurrent(session) else { throw CancellationError() }
            cache.rollbackOptimistic(removal, to: before, token: session)
            throw error
        }
        if cache.isCurrent(session) { cache.commitOptimistic(removal, token: session) }
        return true
    }
}
