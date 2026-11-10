import ABSAPI
import ABSCore
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
    public init() {}
    public func markFinished(_ target: ItemActionTarget) async throws {}
    public func markNotFinished(_ target: ItemActionTarget) async throws {}
    public func hideFromContinueListening(_ target: ItemActionTarget) async throws {}
}

/// Sends a progress change (`PATCH /api/me/progress/:item[/:episode]`); `APIClient` conforms.
public protocol ProgressWriting: Sendable {
    func writeProgress(itemID: String, episodeID: String?, update: MediaProgressUpdate) async throws
}

extension APIClient: ProgressWriting {
    public func writeProgress(itemID: String, episodeID: String?, update: MediaProgressUpdate) async throws {
        _ = try await send(ProgressEndpoints.update(itemID: itemID, episodeID: episodeID, update))
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
/// - An action runs to completion even if its caller is cancelled, so the cache and the server
///   don't end up disagreeing about a half-done action.
/// - Optimistic ordering is tracked separately from server timestamps. A full progress seed
///   requested after a successful action reconciles its authoritative row, even with clock skew.
/// - The local playback database isn't touched; reconciling it with a newer server value is the
///   syncer's job (P2-06d, #158).
@MainActor
public final class ProgressItemActions: ItemActionPerforming {
    private struct Tail {
        let ticket: Int
        let task: Task<Result<Void, any Error>, Never>
    }

    private let cache: ProgressCache
    private let writer: any ProgressWriting
    private let now: @Sendable () -> Date
    private let sessionToken: ProgressCache.SessionToken
    private var tails: [String: Tail] = [:]
    private var tickets = 0

    public init(cache: ProgressCache, writer: any ProgressWriting, now: @escaping @Sendable () -> Date = { Date() }) {
        self.cache = cache
        self.writer = writer
        self.now = now
        self.sessionToken = cache.sessionToken()
    }

    public func markFinished(_ target: ItemActionTarget) async throws {
        try await run(target, update: .finished(true, at: now())) { existing, date in
            Self.finished(target, existing: existing, at: date)
        }
    }

    public func markNotFinished(_ target: ItemActionTarget) async throws {
        try await run(target, update: .finished(false)) { existing, _ in
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

    private func run(
        _ target: ItemActionTarget, update: MediaProgressUpdate,
        optimistic: @escaping @MainActor (MediaProgress?, Date) -> MediaProgress?
    ) async throws {
        let actionSession = cache.sessionToken()
        guard actionSession == sessionToken else { throw CancellationError() }
        let key = target.key
        let previous = tails[key]?.task
        tickets += 1
        let ticket = tickets
        let task = Task<Result<Void, any Error>, Never> { @MainActor in
            _ = await previous?.value
            do {
                try await self.perform(
                    target, update: update, optimistic: optimistic, session: actionSession)
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
        guard cache.isCurrent(session) else { throw CancellationError() }
        if let applied { cache.commitOptimistic(applied, token: session) }
    }
}
