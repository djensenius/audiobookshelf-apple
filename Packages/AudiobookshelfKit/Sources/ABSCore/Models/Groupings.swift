import Foundation

/// A library-wide collection of books. Named to avoid clashing with `Swift.Collection`.
public struct LibraryCollection: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let libraryId: String
    public let userId: String?
    public let name: String
    public let description: String?
    public let cover: String?
    public let coverFullPath: String?
    /// Expanded library items.
    public let books: [LibraryItem]?
    /// Epoch milliseconds.
    public let lastUpdate: Int?
    /// Epoch milliseconds.
    public let createdAt: Int?

    public init(
        id: String, libraryId: String, userId: String? = nil, name: String, description: String? = nil,
        cover: String? = nil, coverFullPath: String? = nil, books: [LibraryItem]? = nil, lastUpdate: Int? = nil,
        createdAt: Int? = nil
    ) {
        self.id = id
        self.libraryId = libraryId
        self.userId = userId
        self.name = name
        self.description = description
        self.cover = cover
        self.coverFullPath = coverFullPath
        self.books = books
        self.lastUpdate = lastUpdate
        self.createdAt = createdAt
    }
}

/// A user's playlist of books and podcast episodes.
public struct Playlist: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let libraryId: String
    public let userId: String?
    public let name: String
    public let description: String?
    public let coverPath: String?
    public let items: [PlaylistItem]
    /// Epoch milliseconds.
    public let lastUpdate: Int?
    /// Epoch milliseconds.
    public let createdAt: Int?

    public init(
        id: String, libraryId: String, userId: String? = nil, name: String, description: String? = nil,
        coverPath: String? = nil, items: [PlaylistItem] = [], lastUpdate: Int? = nil, createdAt: Int? = nil
    ) {
        self.id = id
        self.libraryId = libraryId
        self.userId = userId
        self.name = name
        self.description = description
        self.coverPath = coverPath
        self.items = items
        self.lastUpdate = lastUpdate
        self.createdAt = createdAt
    }
}

public struct PlaylistItem: Sendable, Hashable, Codable, Identifiable {
    public let libraryItemId: String
    public let episodeId: String?
    /// Present for podcast episodes in expanded playlists.
    public let episode: PodcastEpisode?
    public let libraryItem: LibraryItem?

    public init(
        libraryItemId: String, episodeId: String? = nil, episode: PodcastEpisode? = nil,
        libraryItem: LibraryItem? = nil
    ) {
        self.libraryItemId = libraryItemId
        self.episodeId = episodeId
        self.episode = episode
        self.libraryItem = libraryItem
    }

    public var id: String {
        if let episodeId { "\(libraryItemId)-\(episodeId)" } else { libraryItemId }
    }
}
