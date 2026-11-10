import ABSCore
import Foundation
import Observation

/// The signed-in user's server progress, in memory, keyed by item and episode
/// (``MediaProgress/key(libraryItemID:episodeID:)``).
///
/// Seed it with the user's `mediaProgress` (from `GET /api/me` or the login response) and feed
/// it single updates with ``apply(_:)`` from local playback and, later, the socket. An update
/// never replaces a newer one: the entry with the later `lastUpdate` wins, and an update without
/// `lastUpdate` counts as older than any that has one. Clear it on logout or an account switch.
@MainActor
@Observable
public final class ProgressCache {
    public private(set) var entries: [String: MediaProgress] = [:]

    public init() {}

    public func progress(libraryItemID: String, episodeID: String? = nil) -> MediaProgress? {
        entries[MediaProgress.key(libraryItemID: libraryItemID, episodeID: episodeID)]
    }

    /// Replaces the cache with the server's full list. Entries missing from it are removed, except
    /// that an entry already newer than its seeded value is kept.
    public func seed(_ progress: [MediaProgress]) {
        var seeded: [String: MediaProgress] = [:]
        for item in progress {
            if let existing = seeded[item.progressKey], !Self.isNewer(item, than: existing) { continue }
            seeded[item.progressKey] = item
        }
        for (key, existing) in entries {
            if let incoming = seeded[key], !Self.isNewer(incoming, than: existing) {
                seeded[key] = existing
            }
        }
        entries = seeded
    }

    /// Stores `progress` unless the cached entry for the same media is newer. Returns whether it
    /// was stored.
    @discardableResult
    public func apply(_ progress: MediaProgress) -> Bool {
        let key = progress.progressKey
        if let existing = entries[key], !Self.isNewer(progress, than: existing) { return false }
        entries[key] = progress
        return true
    }

    /// Removes the entry for a media item, for example after the server deleted its progress.
    public func remove(libraryItemID: String, episodeID: String? = nil) {
        entries[MediaProgress.key(libraryItemID: libraryItemID, episodeID: episodeID)] = nil
    }

    public func clear() {
        entries = [:]
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
