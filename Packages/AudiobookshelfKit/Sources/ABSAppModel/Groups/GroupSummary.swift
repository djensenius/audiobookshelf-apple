import ABSAPI
import ABSCore
import Foundation

/// A collection or playlist as shown on a list card: what the card shows, never the whole
/// ``LibraryCollection`` or ``Playlist``.
public struct GroupSummary: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case collection
        case playlist
    }

    public let id: String
    public let kind: Kind
    public let name: String
    /// Books in a collection; books and episodes in a playlist.
    public let itemCount: Int
    /// The covers of the first members for the group cover, at most ``maxCovers``. A member
    /// without a cover is skipped, and so is one whose item's cover is already listed (a
    /// playlist of one podcast's episodes shows that cover once).
    public let covers: [CoverRef]

    public static let maxCovers = 4

    public init(id: String, kind: Kind, name: String, itemCount: Int, covers: [CoverRef] = []) {
        self.id = id
        self.kind = kind
        self.name = name
        self.itemCount = itemCount
        self.covers = Array(covers.prefix(Self.maxCovers))
    }

    public init(collection: LibraryCollection) {
        let books = collection.books ?? []
        self.init(
            id: collection.id, kind: .collection, name: collection.name, itemCount: books.count,
            covers: Self.covers(of: books))
    }

    public init(playlist: Playlist) {
        self.init(
            id: playlist.id, kind: .playlist, name: playlist.name, itemCount: playlist.items.count,
            covers: Self.covers(of: playlist.items.compactMap(\.libraryItem)))
    }

    /// The first ``maxCovers`` distinct covers of `items`, in order.
    static func covers(of items: [LibraryItem]) -> [CoverRef] {
        var seen: Set<String> = []
        var covers: [CoverRef] = []
        for item in items where covers.count < maxCovers {
            guard let cover = CoverRef(item: item), seen.insert(cover.entityID).inserted else { continue }
            covers.append(cover)
        }
        return covers
    }
}

/// The book or episode a play-all would start: what the caller passes to playback.
public struct GroupPlayTarget: Sendable, Hashable {
    public let itemID: String
    public let episodeID: String?

    public init(itemID: String, episodeID: String? = nil) {
        self.itemID = itemID
        self.episodeID = episodeID
    }

    /// The key progress is stored under (``MediaProgress/key(libraryItemID:episodeID:)``).
    public var progressKey: String { MediaProgress.key(libraryItemID: itemID, episodeID: episodeID) }
}

/// One row of a collection or playlist: a book, or a podcast episode in a playlist.
public struct GroupMember: Sendable, Hashable, Identifiable {
    /// The item ID, or `"<item>-<episode>"` for an episode, like ``PlaylistItem/id``.
    public var id: String { target.progressKey }
    public let target: GroupPlayTarget
    /// The row's display values. Its flags agree with ``isPlayable``: `isMissing` is set when the
    /// item is missing or invalid, or its playlist expansion is absent or failed to decode, and
    /// `hasAudio` when the book has audio tracks or the episode an audio file. A playlist entry
    /// whose item failed to decode keeps its row, titled with its ID; an episode whose episode
    /// failed to decode keeps the podcast's subtitle and cover and is titled with its ID. (A
    /// collection's malformed book is dropped when the response decodes, so it has no row.)
    public let summary: ItemSummary
    /// It can be played: the item isn't missing or invalid, and has audio tracks or, for an
    /// episode, an audio file; that is, `!summary.isMissing && summary.hasAudio` for members
    /// built from a book or playlist item. A port of `playableItems` in the legacy
    /// `pages/collection/_id.vue` and `pages/playlist/_id.vue`.
    public let isPlayable: Bool

    public init(target: GroupPlayTarget, summary: ItemSummary, isPlayable: Bool) {
        self.target = target
        self.summary = summary
        self.isPlayable = isPlayable
    }

    /// A collection's book.
    public init(book: LibraryItem) {
        self.init(itemID: book.id, episodeID: nil, item: book, episode: nil)
    }

    /// A playlist's book or episode.
    public init(playlistItem: PlaylistItem) {
        self.init(
            itemID: playlistItem.libraryItemId, episodeID: playlistItem.episodeId, item: playlistItem.libraryItem,
            episode: playlistItem.episode)
    }

    private init(itemID: String, episodeID: String?, item: LibraryItem?, episode: PodcastEpisode?) {
        // An empty episode ID counts as none, as in progress keys.
        let episodeID = episodeID.flatMap { $0.isEmpty ? nil : $0 }
        let target = GroupPlayTarget(itemID: itemID, episodeID: episodeID)
        let isPresent = Self.isPresent(item: item, episodeID: episodeID, episode: episode)
        let hasAudio = Self.hasAudio(item: item, episodeID: episodeID, episode: episode)
        let summary: ItemSummary
        if let item, let episodeID, item.mediaType == .podcast {
            summary = ItemSummary(
                item: item, episode: episode ?? PodcastEpisode(id: episodeID, title: target.progressKey))
        } else if let item, episodeID == nil {
            summary = ItemSummary(item: item)
        } else {
            summary = ItemSummary(
                id: target.progressKey, itemID: itemID, episodeID: episodeID, kind: episodeID == nil ? .book : .episode,
                title: target.progressKey)
        }
        self.init(
            target: target, summary: summary.with(isMissing: !isPresent, hasAudio: hasAudio),
            isPlayable: isPresent && hasAudio)
    }

    /// The item is there and valid, and an episode entry has its episode.
    static func isPresent(item: LibraryItem?, episodeID: String?, episode: PodcastEpisode?) -> Bool {
        guard let item, !item.isMissing, !item.isInvalid else { return false }
        return episodeID == nil || episode != nil
    }

    /// The episode has an audio file, or the book audio tracks.
    static func hasAudio(item: LibraryItem?, episodeID: String?, episode: PodcastEpisode?) -> Bool {
        if episodeID != nil { return episode?.audioFile != nil }
        guard let book = item?.book else { return false }
        return (book.tracks?.count ?? book.numTracks ?? 0) > 0
    }
}

extension ItemSummary {
    /// The summary with `isMissing` and `hasAudio` replaced.
    fileprivate func with(isMissing: Bool, hasAudio: Bool) -> ItemSummary {
        ItemSummary(
            id: id, itemID: itemID, episodeID: episodeID, seriesID: seriesID, kind: kind, title: title,
            subtitle: subtitle, seriesText: seriesText, duration: duration, bookCount: bookCount, cover: cover,
            isExplicit: isExplicit, isAbridged: isAbridged, isMissing: isMissing, hasAudio: hasAudio)
    }
}

extension ItemListModel where Query == String, Item == GroupSummary {
    /// The collections of the library `libraryID`, the model's query; ``setQuery(_:)`` with
    /// another library ID switches libraries.
    ///
    /// Like every ``ItemListModel``, it belongs to one account: views create it per account
    /// identity and recreate it when the identity changes.
    public static func collections(
        service: any GroupsService, libraryID: String, pageSize: Int = 20, prefetchThreshold: Int = 5,
        connectionKey: LibraryConnectionKey? = nil
    ) -> ItemListModel {
        ItemListModel(
            query: libraryID, pageSize: pageSize, prefetchThreshold: prefetchThreshold, connectionKey: connectionKey
        ) { libraryID, page, limit in
            try await service.collectionsPage(libraryID: libraryID, page: page, limit: limit)
                .map(GroupSummary.init(collection:))
        }
    }

    /// The user's playlists in the library `libraryID`, the model's query; ``setQuery(_:)`` with
    /// another library ID switches libraries. Belongs to one account, like ``collections(service:libraryID:pageSize:prefetchThreshold:connectionKey:)``.
    public static func playlists(
        service: any GroupsService, libraryID: String, pageSize: Int = 20, prefetchThreshold: Int = 5,
        connectionKey: LibraryConnectionKey? = nil
    ) -> ItemListModel {
        ItemListModel(
            query: libraryID, pageSize: pageSize, prefetchThreshold: prefetchThreshold, connectionKey: connectionKey
        ) { libraryID, page, limit in
            try await service.playlistsPage(libraryID: libraryID, page: page, limit: limit)
                .map(GroupSummary.init(playlist:))
        }
    }
}
