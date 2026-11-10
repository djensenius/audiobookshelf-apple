/// Creates a library-wide collection. All book IDs are library-item IDs, not media IDs.
public struct CollectionCreateRequest: Encodable, Sendable {
    public let name: String
    public let libraryID: String
    /// Nonempty ordered membership. Unknown, wrong-library, non-book or duplicate IDs fail atomically.
    public let bookIDs: [String]
    public let description: String?

    public init(name: String, libraryID: String, bookIDs: [String], description: String? = nil) {
        self.name = name
        self.libraryID = libraryID
        self.bookIDs = bookIDs
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case name, description
        case libraryID = "libraryId"
        case bookIDs = "books"
    }
}

/// Updates metadata or reorders a collection; nil fields are omitted, not encoded as null.
public struct CollectionUpdateRequest: Encodable, Sendable {
    public let name: String?
    /// Pass `""` to clear the description.
    public let description: String?
    /// Reorder ONLY: a full permutation of the current library-item IDs, not replacement membership.
    /// Nil or an empty array leaves membership and order unchanged. Use batch add/remove for membership.
    public let bookIDsInOrder: [String]?

    public init(name: String? = nil, description: String? = nil, bookIDsInOrder: [String]? = nil) {
        self.name = name
        self.description = description
        self.bookIDsInOrder = bookIDsInOrder
    }

    enum CodingKeys: String, CodingKey {
        case name, description
        case bookIDsInOrder = "books"
    }
}

/// Batch membership changes use library-item IDs, never book/media IDs.
public struct CollectionBooksRequest: Encodable, Sendable {
    public let bookIDs: [String]

    public init(bookIDs: [String]) {
        self.bookIDs = bookIDs
    }

    enum CodingKeys: String, CodingKey {
        case bookIDs = "books"
    }
}
