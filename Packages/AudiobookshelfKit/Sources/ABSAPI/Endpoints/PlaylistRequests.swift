/// A known valid playlist member: books use only a library-item ID; podcast episodes require
/// both the correct library-item ID and episode ID. Never use a book/media ID.
/// Callers must enforce valid kind, same-library membership and uniqueness using item metadata.
/// Requests intentionally do not perform metadata-dependent validation.
public struct PlaylistItemReference: Encodable, Sendable {
    public let libraryItemID: String
    public let episodeID: String?

    public init(libraryItemID: String, episodeID: String? = nil) {
        self.libraryItemID = libraryItemID
        self.episodeID = episodeID
    }

    enum CodingKeys: String, CodingKey {
        case libraryItemID = "libraryItemId"
        case episodeID = "episodeId"
    }
}

/// Creates an owned playlist. Supply unique, valid references from the specified library.
public struct PlaylistCreateRequest: Encodable, Sendable {
    public let name: String
    public let libraryID: String
    public let items: [PlaylistItemReference]
    public let description: String?

    public init(name: String, libraryID: String, items: [PlaylistItemReference], description: String? = nil) {
        self.name = name
        self.libraryID = libraryID
        self.items = items
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case name, items, description
        case libraryID = "libraryId"
    }
}

/// Nil fields are omitted. Empty name/description strings are ignored, not clearing operations.
public struct PlaylistUpdateRequest: Encodable, Sendable {
    public let name: String?
    public let description: String?
    /// Full permutation of existing references, NOT replacement membership. Nil/empty is a no-op.
    /// Callers must supply every existing member exactly once, with its correct episode identity.
    public let itemsInOrder: [PlaylistItemReference]?

    public init(name: String? = nil, description: String? = nil, itemsInOrder: [PlaylistItemReference]? = nil) {
        self.name = name
        self.description = description
        self.itemsInOrder = itemsInOrder
    }

    enum CodingKeys: String, CodingKey {
        case name, description
        case itemsInOrder = "items"
    }
}

/// Nonempty unique references from the playlist's library. Use correct book/episode identities;
/// the server does not safely validate every invalid combination.
public struct PlaylistItemsRequest: Encodable, Sendable {
    public let items: [PlaylistItemReference]

    public init(items: [PlaylistItemReference]) {
        self.items = items
    }
}
