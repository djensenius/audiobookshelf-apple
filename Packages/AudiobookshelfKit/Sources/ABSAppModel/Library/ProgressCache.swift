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
/// Observation is per key: ``progress(libraryItemID:episodeID:)`` only tracks its own entry, so
/// an update to one item doesn't invalidate views showing other items.
///
/// Entries are created on first read, so reading items without progress (for example scrolling
/// a grid) grows the cache by one empty entry per item read. Those can't be pruned safely,
/// because a view may be watching one for its first progress; ``clear()`` (logout or account
/// switch) drops them. Entries whose progress is removed are dropped right away: their readers
/// are notified by the removal and create a new entry when they read again.
@MainActor
public final class ProgressCache {
    /// One observable entry per key, created on first read or write.
    @MainActor
    @Observable
    final class Entry {
        var value: MediaProgress?
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public func progress(libraryItemID: String, episodeID: String? = nil) -> MediaProgress? {
        entry(for: MediaProgress.key(libraryItemID: libraryItemID, episodeID: episodeID)).value
    }

    /// Replaces the cache with the server's full list, fetched with a request sent at `fetchedAt`.
    ///
    /// - A seeded row replaces the cached entry unless the cached one is newer.
    /// - A cached entry missing from the list is removed, unless its `lastUpdate` is later than
    ///   `fetchedAt`: it was then applied (for example by local playback starting a new item)
    ///   after the server built the list, so the list can't know about it.
    ///
    /// `fetchedAt` must be on the same clock as the `lastUpdate` of progress passed to
    /// ``apply(_:)``: record it on the device just before sending the request, and stamp local
    /// progress with the device clock. Progress the server stamped (socket updates) uses the
    /// server's clock, so with clock skew an entry missing from the list may be kept or removed
    /// wrongly; the next seed or update corrects it.
    public func seed(_ progress: [MediaProgress], fetchedAt: Date) {
        let fetchedAtMilliseconds = Int((fetchedAt.timeIntervalSince1970 * 1000).rounded(.down))
        var seeded: [String: MediaProgress] = [:]
        for item in progress {
            if let existing = seeded[item.progressKey], !Self.isNewer(item, than: existing) { continue }
            seeded[item.progressKey] = item
        }
        for (key, entry) in entries {
            guard let existing = entry.value else { continue }
            if let incoming = seeded[key] {
                if !Self.isNewer(incoming, than: existing) { seeded[key] = existing }
            } else if let lastUpdate = existing.lastUpdate, lastUpdate > fetchedAtMilliseconds {
                seeded[key] = existing
            }
        }
        for (key, entry) in entries where seeded[key] == nil && entry.value != nil {
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

    public func clear() {
        // Readers track the entries they read, so empty them before dropping them.
        for entry in entries.values where entry.value != nil {
            entry.value = nil
        }
        entries = [:]
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
}
