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
/// Seeding uses a local ``revision`` rather than timestamps to tell which entries changed while
/// the list was being fetched; see ``seed(_:since:)``.
///
/// Observation is per key: ``progress(libraryItemID:episodeID:)`` only tracks its own entry, so
/// an update to one item doesn't invalidate views showing other items.
///
/// Entries are created on first read, so reading items without progress (for example scrolling
/// a grid) grows the cache by one empty entry per item read. Those are kept for the cache's
/// lifetime, ``clear()`` included, because a view may be watching one for its first progress.
/// Entries whose progress is removed are dropped right away: their readers are notified by the
/// removal and create a new entry when they read again.
@MainActor
public final class ProgressCache {
    /// One observable entry per key, created on first read or write.
    @MainActor
    @Observable
    final class Entry {
        var value: MediaProgress?
        /// The cache ``ProgressCache/revision`` of the last ``ProgressCache/apply(_:)`` that
        /// stored a value here, or 0.
        @ObservationIgnored var revision = 0
    }

    private var entries: [String: Entry] = [:]

    /// Increases with every ``apply(_:)`` that stores progress. Capture it just before requesting
    /// the list passed to ``seed(_:since:)``.
    public private(set) var revision = 0

    public init() {}

    public func progress(libraryItemID: String, episodeID: String? = nil) -> MediaProgress? {
        entry(for: MediaProgress.key(libraryItemID: libraryItemID, episodeID: episodeID)).value
    }

    /// Replaces the cache with the server's full list.
    ///
    /// `boundary` is ``revision`` read just before the list was requested:
    ///
    /// ```swift
    /// let boundary = cache.revision
    /// let me = try await client.me()
    /// cache.seed(me.mediaProgress, since: boundary)
    /// ```
    ///
    /// - An entry applied after `boundary` may be missing from or older in the list, so it is
    ///   kept unless the list has a row for it with a later `lastUpdate` (both dated).
    /// - Any other entry missing from the list is removed.
    /// - Any other entry listed takes the list's row unless the cached one is newer (for example
    ///   local progress not synced yet).
    ///
    /// Timestamps aren't compared with the request time, so undated progress and clock skew
    /// between the device and the server don't matter.
    public func seed(_ progress: [MediaProgress], since boundary: Int) {
        var seeded: [String: MediaProgress] = [:]
        for item in progress {
            if let existing = seeded[item.progressKey], !Self.isNewer(item, than: existing) { continue }
            seeded[item.progressKey] = item
        }
        for (key, entry) in entries {
            guard let existing = entry.value else { continue }
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

    /// Removes the entry for a media item, for example after the server deleted its progress.
    public func remove(libraryItemID: String, episodeID: String? = nil) {
        let key = MediaProgress.key(libraryItemID: libraryItemID, episodeID: episodeID)
        guard let entry = entries[key], entry.value != nil else { return }
        entry.value = nil
        entries[key] = nil
    }

    /// Empties every entry. The entry objects are kept, so views watching a key (even one that
    /// had no progress) see the next ``apply(_:)`` or ``seed(_:since:)`` for it.
    public func clear() {
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
