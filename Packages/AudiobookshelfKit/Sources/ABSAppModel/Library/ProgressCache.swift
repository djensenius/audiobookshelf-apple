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
        /// The cache ``ProgressCache/revision`` of the last ``ProgressCache/apply(_:)`` that
        /// stored a value here or ``ProgressCache/remove(libraryItemID:episodeID:)``, or 0.
        @ObservationIgnored var revision = 0
    }

    /// Identifies one request for the full list; see ``beginSeed()``.
    public struct SeedToken: Sendable, Equatable {
        let generation: Int
        let request: Int
        /// ``ProgressCache/revision`` when the request started.
        let boundary: Int
    }

    private var entries: [String: Entry] = [:]
    /// Bumped by ``clear()``, so tokens issued before it are stale.
    private var generation = 0
    private var seedRequests = 0
    /// The request of the last seed applied in this generation.
    private var appliedSeedRequest = 0

    /// Increases with every ``apply(_:)`` that stores progress and every
    /// ``remove(libraryItemID:episodeID:)``.
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
        return SeedToken(generation: generation, request: seedRequests, boundary: revision)
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
                // A tombstone: removed while the list was being fetched.
                if entry.revision > boundary { seeded[key] = nil }
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
            entries[key] = nil
        }
        for (key, value) in seeded {
            let entry = entry(for: key)
            if entry.value != value { entry.value = value }
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
        entry.revision = revision
        entry.value = progress
        return true
    }

    /// Puts `previous` back (or removes the entry when it is `nil`), but only while the entry
    /// still holds `applied`: an update that arrived since (the socket, local playback, another
    /// action) is newer and stays. Returns whether the entry was restored.
    @discardableResult
    public func rollback(_ applied: MediaProgress, to previous: MediaProgress?) -> Bool {
        let entry = entry(for: applied.progressKey)
        guard entry.value == applied else { return false }
        revision += 1
        entry.revision = revision
        entry.value = previous
        return true
    }

    /// Removes the progress of a media item, for example after the server deleted it. The entry
    /// stays as a tombstone, so seeds requested before now don't restore the progress.
    public func remove(libraryItemID: String, episodeID: String? = nil) {
        let entry = entry(for: MediaProgress.key(libraryItemID: libraryItemID, episodeID: episodeID))
        revision += 1
        entry.revision = revision
        if entry.value != nil { entry.value = nil }
    }

    /// Empties every entry. The entry objects are kept, so views watching a key (even one that
    /// had no progress) see the next ``apply(_:)`` or ``seed(_:token:)`` for it. Seed requests
    /// started before it are dropped when they respond.
    public func clear() {
        generation += 1
        appliedSeedRequest = 0
        for entry in entries.values {
            entry.revision = 0
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
