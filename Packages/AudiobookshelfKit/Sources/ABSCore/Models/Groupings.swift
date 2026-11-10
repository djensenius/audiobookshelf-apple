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

    enum CodingKeys: String, CodingKey {
        case id, libraryId, userId, name, description, cover, coverFullPath, books, lastUpdate, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        libraryId = try container.decode(String.self, forKey: .libraryId)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        cover = try container.decodeIfPresent(String.self, forKey: .cover)
        coverFullPath = try container.decodeIfPresent(String.self, forKey: .coverFullPath)
        books = try container.decodeLossyArrayIfPresent(LibraryItem.self, forKey: .books)
        lastUpdate = try container.decodeIfPresent(Int.self, forKey: .lastUpdate)
        createdAt = try container.decodeIfPresent(Int.self, forKey: .createdAt)
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

    enum CodingKeys: String, CodingKey {
        case id, libraryId, userId, name, description, coverPath, items, lastUpdate, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        libraryId = try container.decode(String.self, forKey: .libraryId)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        coverPath = try container.decodeIfPresent(String.self, forKey: .coverPath)
        items = try container.decode(LossyArray<PlaylistItem>.self, forKey: .items).elements
        lastUpdate = try container.decodeIfPresent(Int.self, forKey: .lastUpdate)
        createdAt = try container.decodeIfPresent(Int.self, forKey: .createdAt)
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

    enum CodingKeys: String, CodingKey {
        case libraryItemId, episodeId, episode, libraryItem
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        libraryItemId = try container.decode(String.self, forKey: .libraryItemId)
        episodeId = try container.decodeIfPresent(String.self, forKey: .episodeId)
        // Expansions are optional detail, not identity. A malformed expansion must not
        // discard an otherwise identifiable member or turn an episode into a book.
        episode = try? container.decodeIfPresent(PodcastEpisode.self, forKey: .episode)
        libraryItem = try? container.decodeIfPresent(LibraryItem.self, forKey: .libraryItem)
    }

    public var id: String {
        if let episodeId { "\(libraryItemId)-\(episodeId)" } else { libraryItemId }
    }
}
