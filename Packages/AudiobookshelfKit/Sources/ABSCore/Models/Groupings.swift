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
}

public struct PlaylistItem: Sendable, Hashable, Codable, Identifiable {
    public let libraryItemId: String
    public let episodeId: String?
    /// Present for podcast episodes in expanded playlists.
    public let episode: PodcastEpisode?
    public let libraryItem: LibraryItem?

    public var id: String {
        if let episodeId { "\(libraryItemId)-\(episodeId)" } else { libraryItemId }
    }
}
