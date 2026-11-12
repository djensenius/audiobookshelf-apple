import ABSAPI
import ABSCore
import Foundation
import Observation

/// A book (`episodeID` nil) or podcast episode to add to playlists.
public struct PlaylistEntryKey: Sendable, Hashable {
    public let itemID: String
    public let episodeID: String?

    public init(itemID: String, episodeID: String? = nil) {
        self.itemID = itemID
        self.episodeID = episodeID
    }

    /// The playlist member the server knows this entry as.
    public var reference: PlaylistItemReference {
        PlaylistItemReference(libraryItemID: itemID, episodeID: episodeID)
    }

    /// `item` is this book, or this exact episode: another episode of the same podcast isn't.
    func matches(_ item: PlaylistItem) -> Bool {
        item.libraryItemId == itemID && item.episodeId == episodeID
    }
}

/// The add-to-playlist sheet; a port of the legacy `components/modals/playlists/AddCreateModal.vue`.
/// It lists the user's playlists in one library, checks those that already contain every entry,
/// and adds or removes the entries from a playlist, or creates a playlist with them.
///
/// - A playlist is checked only when it contains **all** the entries, as in legacy. Toggling a
///   checked playlist removes them all; toggling an unchecked one adds the missing ones.
/// - Toggles are optimistic: the row changes at once and takes the server's playlist when the
///   request succeeds, or goes back to what it was and sets ``failure`` when it fails. A second
///   toggle of a playlist with a request in flight is ignored.
/// - Removing a playlist's last member deletes it on the server, so its row is dropped.
/// - Rows are ordered once per load, checked playlists first (legacy re-sorted on every change,
///   which would move a row under the user's finger). A created playlist goes first.
///
/// The app has no shared playlist store: the Playlists screens load their own pages, so they show
/// these changes when they next load. The model belongs to one account, like ``GroupDetailModel``.
@MainActor
@Observable
public final class AddToPlaylistModel {
    /// A failed action, for the view's alert.
    public enum Failure: Sendable, Hashable {
        case add, remove, create
    }

    /// One playlist as the sheet lists it.
    public struct Row: Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
        /// The server's entries, including the entries just toggled.
        public let itemCount: Int
        /// The playlist contains every entry.
        public let isChecked: Bool
        /// A toggle of this playlist is in flight.
        public let isUpdating: Bool
    }

    public let libraryID: String
    /// The books and episodes to add, without duplicates, in the caller's order.
    public let entries: [PlaylistEntryKey]

    /// The user's playlists, in row order.
    public private(set) var playlists: [Playlist] = []
    public private(set) var hasLoaded = false
    public private(set) var isLoading = false
    /// The last load failed; cleared by the next successful one.
    public private(set) var loadFailed = false
    /// The last toggle or create failed; ``clearFailure()`` hides it.
    public private(set) var failure: Failure?
    /// Playlists with a toggle in flight.
    public private(set) var updatingIDs: Set<String> = []
    public private(set) var isCreating = false

    @ObservationIgnored private let service: any PlaylistEditingService
    @ObservationIgnored private var loadSequence = 0

    public init(entries: [PlaylistEntryKey], libraryID: String, service: any PlaylistEditingService) {
        var seen = Set<PlaylistEntryKey>()
        self.entries = entries.filter { seen.insert($0).inserted }
        self.libraryID = libraryID
        self.service = service
    }

    public var rows: [Row] {
        playlists.map { playlist in
            Row(
                id: playlist.id, name: playlist.name, itemCount: playlist.items.count,
                isChecked: containsAll(playlist), isUpdating: updatingIDs.contains(playlist.id))
        }
    }

    /// `playlist` contains every entry; never true without entries.
    public func containsAll(_ playlist: Playlist) -> Bool {
        !entries.isEmpty && entries.allSatisfy { entry in playlist.items.contains(where: entry.matches) }
    }

    /// Loads the playlists. A response to an older call that arrives after a newer one started is
    /// dropped; a failed reload keeps the loaded list.
    public func load() async {
        loadSequence += 1
        let sequence = loadSequence
        isLoading = true
        let result: Result<[Playlist], any Error>
        do {
            result = .success(try await service.allPlaylists(libraryID: libraryID))
        } catch {
            result = .failure(error)
        }
        guard sequence == loadSequence else { return }
        isLoading = false
        switch result {
        case .success(let loaded):
            // Checked first, otherwise in the server's order.
            playlists = loaded.filter(containsAll) + loaded.filter { !containsAll($0) }
            hasLoaded = true
            loadFailed = false
        case .failure(let error):
            if !(error is CancellationError) { loadFailed = true }
        }
    }

    /// Adds the entries to the playlist `id`, or removes them when it contains them all.
    public func toggle(playlistID id: String) async {
        guard !entries.isEmpty, !updatingIDs.contains(id), let previous = playlist(id) else { return }
        updatingIDs.insert(id)
        defer { updatingIDs.remove(id) }
        let isRemoving = containsAll(previous)
        let changed = isRemoving ? entries : entries.filter { entry in !previous.items.contains(where: entry.matches) }
        let optimistic =
            isRemoving
            ? previous.items.filter { item in !entries.contains { $0.matches(item) } }
            : previous.items + changed.map { PlaylistItem(libraryItemId: $0.itemID, episodeId: $0.episodeID) }
        replace(previous.with(items: optimistic))
        do {
            let references = changed.map(\.reference)
            let updated =
                isRemoving
                ? try await service.removeFromPlaylist(id: id, items: references)
                : try await service.addToPlaylist(id: id, items: references)
            if updated.items.isEmpty {
                playlists.removeAll { $0.id == id }
            } else {
                replace(updated)
            }
        } catch {
            replace(previous)
            if !(error is CancellationError) { failure = isRemoving ? .remove : .add }
        }
    }

    /// Creates a playlist named `name` (trimmed) with the entries, listed first. Returns whether it
    /// was created; a blank name, no entries or a create in flight does nothing.
    @discardableResult
    public func create(name: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !entries.isEmpty, !isCreating else { return false }
        isCreating = true
        defer { isCreating = false }
        do {
            let created = try await service.createPlaylist(
                name: name, libraryID: libraryID, items: entries.map(\.reference))
            playlists.removeAll { $0.id == created.id }
            playlists.insert(created, at: 0)
            return true
        } catch {
            if !(error is CancellationError) { failure = .create }
            return false
        }
    }

    public func clearFailure() {
        failure = nil
    }

    private func playlist(_ id: String) -> Playlist? {
        playlists.first { $0.id == id }
    }

    /// Replaces the listed playlist with `playlist`'s ID; a playlist no longer listed stays out.
    private func replace(_ playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index] = playlist
    }
}

extension Playlist {
    fileprivate func with(items: [PlaylistItem]) -> Playlist {
        Playlist(
            id: id, libraryId: libraryId, userId: userId, name: name, description: description, coverPath: coverPath,
            items: items, lastUpdate: lastUpdate, createdAt: createdAt)
    }
}
