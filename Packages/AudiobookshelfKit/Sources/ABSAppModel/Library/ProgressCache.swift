import ABSCore
import Foundation
import Observation

/// The signed-in user's server progress, in memory, keyed by item and episode
/// (``MediaProgress/key(libraryItemID:episodeID:)``).
///
/// Seed it with the user's `mediaProgress` (from `GET /api/me` or the login response) and feed
/// it single updates with ``apply(_:)`` from local playback and, later, the socket. An update
/// never replaces a newer one: the entry with the later `lastUpdate` wins, and an update without
/// `lastUpdate` counts as older than any that has one. ``LibraryStore`` owns the cache and clears
/// it on logout and account switches.
///
/// Seeding uses a ``SeedToken`` taken before the request: it rejects superseded or
/// previous-account responses, and holds a local ``revision`` (rather than timestamps) to tell
/// which entries changed while the list was being fetched; see ``seed(_:token:)``.
///
/// Observation is per key: ``progress(libraryItemID:episodeID:)`` only tracks its own entry, so
/// an update to one item doesn't invalidate views showing other items.
///
/// Entries are created on first read, so reading items without progress (for example scrolling
/// a grid) grows the cache by one empty entry per item read. Those are kept for the cache's
/// lifetime, ``clear()`` included, because a view may be watching one for its first progress.
/// ``remove(libraryItemID:episodeID:)`` also keeps its entry, as a tombstone stamped with a
/// ``revision``, so a seed requested before the removal can't restore the progress. Tombstones
/// are an empty entry each and aren't pruned. Entries whose progress a seed removes are dropped
/// right away: their readers are notified by the removal and create a new entry when they read
/// again.
@MainActor
public final class ProgressCache {
    /// One observable entry per key, created on first read or write.
    @MainActor
    @Observable
    final class Entry {
        var value: MediaProgress?
        /// The cache ``ProgressCache/revision`` of the last update that stored a value here or
        /// ``ProgressCache/remove(libraryItemID:episodeID:)``, or 0.
        @ObservationIgnored var revision = 0
        /// The `revision` this entry had before its last ``ProgressCache/apply(_:)``; restored by
        /// ``ProgressCache/rollback(_:to:)``.
        @ObservationIgnored var revisionBeforeApply = 0
        @ObservationIgnored var isOptimistic = false
        @ObservationIgnored var optimisticCommitSerial: Int?
    }

    /// Identifies one request for the full list; see ``beginSeed()``.
    public struct SeedToken: Sendable, Equatable {
        let generation: Int
        let request: Int
        /// ``ProgressCache/revision`` when the request started.
        let boundary: Int
        fileprivate let optimisticCommitBoundary: Int
    }

    struct SessionToken: Sendable, Equatable {
        fileprivate let generation: Int
    }

    struct OptimisticUpdate: Sendable {
        fileprivate let key: String
        /// The value applied: `nil` for ``ProgressCache/applyOptimisticRemoval(libraryItemID:episodeID:token:)``.
        fileprivate let progress: MediaProgress?
        fileprivate let revision: Int
        fileprivate let previousRevision: Int
        fileprivate let previousRevisionBeforeApply: Int
        fileprivate let previousIsOptimistic: Bool
        fileprivate let previousCommitSerial: Int?
    }

    private var entries: [String: Entry] = [:]
    /// Bumped by ``clear()``, so tokens issued before it are stale.
    private var generation = 0
    private var seedRequests = 0
    /// The request of the last seed applied in this generation.
    private var appliedSeedRequest = 0
    private var optimisticCommitSerial = 0

    /// Increases with every stored update and every ``remove(libraryItemID:episodeID:)``.
    public private(set) var revision = 0

    public init() {}

    public func progress(libraryItemID: String, episodeID: String? = nil) -> MediaProgress? {
        entry(for: MediaProgress.key(libraryItemID: libraryItemID, episodeID: episodeID)).value
    }

    /// Starts a request for the full list: call it just before sending the request, and pass the
    /// token with the response to ``seed(_:token:)``.
    ///
    /// ```swift
    /// let token = cache.beginSeed()
    /// let me = try await client.me()
    /// cache.seed(me.mediaProgress, token: token)
    /// ```
    public func beginSeed() -> SeedToken {
        seedRequests += 1
        return SeedToken(
            generation: generation, request: seedRequests, boundary: revision,
            optimisticCommitBoundary: optimisticCommitSerial)
    }

    func sessionToken() -> SessionToken {
        SessionToken(generation: generation)
    }

    func isCurrent(_ token: SessionToken) -> Bool {
        token.generation == generation
    }

    /// Replaces the cache with the server's full list, requested with `token`. Returns whether it
    /// was applied.
    ///
    /// Pass only a complete list: the `mediaProgress` of `GET /api/me` or of the login response,
    /// which the server sends whole and unpaged. `User` decodes a missing `mediaProgress` as
    /// empty, and seeding an empty list removes every entry not changed during the request, so
    /// don't seed from payloads that may omit it (the minimal users of `GET /api/users`).
    ///
    /// The response is dropped when ``clear()`` ran since ``beginSeed()`` (logout or another
    /// account), or when a response to a later request was already applied: an older snapshot
    /// never overwrites a newer one. A response that arrives first is applied even if a later
    /// request is still in flight, because the later one may never complete.
    ///
    /// Against the entries, with `boundary` the ``revision`` when the request started:
    /// - An entry applied after `boundary` may be missing from or older in the list, so it is
    ///   kept unless the list has a row for it with a later `lastUpdate` (both dated).
    /// - A successful optimistic action is reconciled by a seed requested after its completion,
    ///   independent of timestamp ordering; a seed already in flight keeps the optimistic value.
    /// - An entry removed after `boundary` stays removed, even if the list has a row for it.
    /// - Any other entry missing from the list is removed.
    /// - Any other entry listed takes the list's row unless the cached one is newer (for example
    ///   local progress not synced yet).
    ///
    /// Timestamps aren't compared with the request time, so undated progress and clock skew
    /// between the device and the server don't matter.
    @discardableResult
    public func seed(_ progress: [MediaProgress], token: SeedToken) -> Bool {
        guard token.generation == generation, token.request > appliedSeedRequest else { return false }
        appliedSeedRequest = token.request
        let boundary = token.boundary
        var seeded: [String: MediaProgress] = [:]
        for item in progress {
            if let existing = seeded[item.progressKey], !Self.isNewer(item, than: existing) { continue }
            seeded[item.progressKey] = item
        }
        for (key, entry) in entries {
            guard let existing = entry.value else {
                // A tombstone: removed while the list was being fetched, or an optimistic removal
                // the server may not have applied when this list was requested.
                if entry.revision > boundary || (entry.isOptimistic && !Self.isCommitted(entry, before: token)) {
                    seeded[key] = nil
                }
                continue
            }
            if entry.isOptimistic {
                guard entry.revision <= boundary,
                    let commitSerial = entry.optimisticCommitSerial,
                    commitSerial <= token.optimisticCommitBoundary
                else {
                    seeded[key] = existing
                    continue
                }
                // This complete server snapshot started after the successful write, so its
                // timestamp is authoritative even when the device clock ran ahead.
                continue
            }
            if entry.revision > boundary {
                if let incoming = seeded[key], Self.isStrictlyNewer(incoming, than: existing) { continue }
                seeded[key] = existing
            } else if let incoming = seeded[key], !Self.isNewer(incoming, than: existing) {
                seeded[key] = existing
            }
        }
        for (key, entry) in entries where seeded[key] == nil && entry.value != nil {
            // A real change, so readers are notified and create a new entry when they read again.
            entry.value = nil
            entry.isOptimistic = false
            entry.optimisticCommitSerial = nil
            entries[key] = nil
        }
        for (key, value) in seeded {
            let entry = entry(for: key)
            if entry.value != value { entry.value = value }
            if entry.isOptimistic, entry.revision <= boundary,
                let commitSerial = entry.optimisticCommitSerial,
                commitSerial <= token.optimisticCommitBoundary
            {
                entry.isOptimistic = false
                entry.optimisticCommitSerial = nil
            }
        }
        return true
    }

    /// Stores `progress` unless the cached entry for the same media is newer. Returns whether it
    /// was stored.
    @discardableResult
    public func apply(_ progress: MediaProgress) -> Bool {
        let entry = entry(for: progress.progressKey)
        if let existing = entry.value, !Self.isNewer(progress, than: existing) { return false }
        revision += 1
        entry.revisionBeforeApply = entry.revision
        entry.revision = revision
        entry.value = progress
        entry.isOptimistic = false
        entry.optimisticCommitSerial = nil
        return true
    }

    func applyOptimistic(_ progress: MediaProgress, token: SessionToken) -> OptimisticUpdate? {
        guard isCurrent(token) else { return nil }
        let entry = entry(for: progress.progressKey)
        let update = stamp(entry, key: progress.progressKey, progress: progress)
        entry.value = progress
        return update
    }

    /// Gives `entry` a new revision for an optimistic update to `progress`, and returns the
    /// update with what a rollback restores.
    private func stamp(_ entry: Entry, key: String, progress: MediaProgress?) -> OptimisticUpdate {
        let update = OptimisticUpdate(
            key: key, progress: progress, revision: revision + 1,
            previousRevision: entry.revision, previousRevisionBeforeApply: entry.revisionBeforeApply,
            previousIsOptimistic: entry.isOptimistic, previousCommitSerial: entry.optimisticCommitSerial)
        revision += 1
        entry.revisionBeforeApply = entry.revision
        entry.revision = revision
        entry.isOptimistic = true
        entry.optimisticCommitSerial = nil
        return update
    }

    /// Whether the optimistic `entry` was committed before the seed of `token` was requested.
    private static func isCommitted(_ entry: Entry, before token: SeedToken) -> Bool {
        guard let commitSerial = entry.optimisticCommitSerial else { return false }
        return commitSerial <= token.optimisticCommitBoundary
    }

    /// Removes the progress of `libraryItemID` and `episodeID` until the server confirms or the
    /// caller rolls back, like ``applyOptimistic(_:token:)`` with a `nil` value.
    ///
    /// The entry is stamped with a new ``revision``, so it is a tombstone for seeds requested
    /// before it, and is marked optimistic, so seeds requested before its commit don't restore
    /// the progress the server still has. ``rollbackOptimistic(_:to:token:)`` puts the progress
    /// back only while the entry still has that revision and no value.
    ///
    /// As with ``rollback(_:to:)``, a seed that arrives while the removal is in flight and is
    /// kept out by it, followed by a failed DELETE, leaves the rollback restoring the pre-image,
    /// which may be older than that seed's row; the next seed corrects it.
    func applyOptimisticRemoval(
        libraryItemID: String, episodeID: String?, token: SessionToken
    ) -> OptimisticUpdate? {
        guard isCurrent(token) else { return nil }
        let key = MediaProgress.key(libraryItemID: libraryItemID, episodeID: episodeID)
        let entry = entry(for: key)
        let update = stamp(entry, key: key, progress: nil)
        if entry.value != nil { entry.value = nil }
        return update
    }

    @discardableResult
    func commitOptimistic(_ update: OptimisticUpdate, token: SessionToken) -> Bool {
        guard isCurrent(token), let entry = entries[update.key],
            entry.revision == update.revision, entry.value == update.progress
        else { return false }
        optimisticCommitSerial += 1
        entry.optimisticCommitSerial = optimisticCommitSerial
        return true
    }

    @discardableResult
    func rollbackOptimistic(
        _ update: OptimisticUpdate, to previous: MediaProgress?, token: SessionToken
    ) -> Bool {
        guard isCurrent(token), let entry = entries[update.key],
            entry.revision == update.revision, entry.value == update.progress
        else { return false }
        entry.revision = update.previousRevision
        entry.revisionBeforeApply = update.previousRevisionBeforeApply
        entry.value = previous
        entry.isOptimistic = update.previousIsOptimistic
        entry.optimisticCommitSerial = update.previousCommitSerial
        return true
    }

    /// Puts `previous` back (or removes the entry when it is `nil`), but only while the entry
    /// still holds `applied`: an update that arrived since (the socket, local playback, another
    /// action) is newer and stays. Returns whether the entry was restored.
    ///
    /// The entry gets the revision it had before `applied`, so the rollback doesn't count as a
    /// local change. That matters in two cases. With a `nil` pre-image, a seed requested before
    /// the optimistic apply still lands when it arrives after the rollback (otherwise the
    /// tombstone would make it skip the entry). With a non-nil pre-image it changes the outcome
    /// only when a list row's `lastUpdate` equals the cached one: the row replaces the entry
    /// instead of the local value being kept.
    ///
    /// A seed that arrives after the optimistic apply and loses to it can leave the rollback
    /// restoring a pre-image older than that seed's row; the next seed corrects it (as before
    /// this change).
    @discardableResult
    public func rollback(_ applied: MediaProgress, to previous: MediaProgress?) -> Bool {
        let entry = entry(for: applied.progressKey)
        guard entry.value == applied else { return false }
        entry.revision = entry.revisionBeforeApply
        entry.value = previous
        entry.isOptimistic = false
        entry.optimisticCommitSerial = nil
        return true
    }

    /// Removes the progress of a media item, for example after the server deleted it. The entry
    /// stays as a tombstone, so seeds requested before now don't restore the progress.
    public func remove(libraryItemID: String, episodeID: String? = nil) {
        let entry = entry(for: MediaProgress.key(libraryItemID: libraryItemID, episodeID: episodeID))
        revision += 1
        entry.revision = revision
        if entry.value != nil { entry.value = nil }
        entry.isOptimistic = false
        entry.optimisticCommitSerial = nil
    }

    /// Empties every entry. The entry objects are kept, so views watching a key (even one that
    /// had no progress) see the next ``apply(_:)`` or ``seed(_:token:)`` for it. Seed requests
    /// started before it are dropped when they respond.
    public func clear() {
        generation += 1
        appliedSeedRequest = 0
        optimisticCommitSerial = 0
        for entry in entries.values {
            entry.revision = 0
            entry.revisionBeforeApply = 0
            entry.isOptimistic = false
            entry.optimisticCommitSerial = nil
            // Setting nil over nil isn't guaranteed to stay silent, so only change real values.
            if entry.value != nil { entry.value = nil }
        }
    }

    /// The keys that have progress; for tests.
    var storedKeys: Set<String> {
        Set(entries.compactMap { $0.value.value == nil ? nil : $0.key })
    }

    /// The number of entries, including empty ones created by reads; for tests.
    var entryCount: Int { entries.count }

    private func entry(for key: String) -> Entry {
        if let entry = entries[key] { return entry }
        let entry = Entry()
        entries[key] = entry
        return entry
    }

    /// Whether `candidate` may replace `existing`: it is at least as recent. Equal timestamps
    /// replace, so a correction made within the same millisecond lands.
    private static func isNewer(_ candidate: MediaProgress, than existing: MediaProgress) -> Bool {
        switch (candidate.lastUpdate, existing.lastUpdate) {
        case (let candidate?, let existing?): candidate >= existing
        case (nil, .some): false
        case (_, nil): true
        }
    }

    /// Whether both are dated and `candidate` is later.
    private static func isStrictlyNewer(_ candidate: MediaProgress, than existing: MediaProgress)
        -> Bool
    {
        guard let candidate = candidate.lastUpdate, let existing = existing.lastUpdate else { return false }
        return candidate > existing
    }
}
