import Foundation

/// An author. Inside book metadata only `id` and `name` are present; author lists add the rest.
public struct Author: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let asin: String?
    public let description: String?
    public let imagePath: String?
    public let libraryId: String?
    /// Epoch milliseconds.
    public let addedAt: Int?
    /// Epoch milliseconds.
    public let updatedAt: Int?
    public let numBooks: Int?

    public init(
        id: String, name: String, asin: String? = nil, description: String? = nil, imagePath: String? = nil,
        libraryId: String? = nil, addedAt: Int? = nil, updatedAt: Int? = nil, numBooks: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.asin = asin
        self.description = description
        self.imagePath = imagePath
        self.libraryId = libraryId
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.numBooks = numBooks
    }
}

/// A series. Inside book metadata it carries the book's `sequence`; series lists and shelves
/// carry `books` (books that fail to decode are skipped).
public struct Series: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let nameIgnorePrefix: String?
    public let description: String?
    public let sequence: String?
    public let libraryId: String?
    /// Epoch milliseconds.
    public let addedAt: Int?
    /// Epoch milliseconds.
    public let updatedAt: Int?
    public let books: [LibraryItem]?
    /// Seconds.
    public let totalDuration: Double?

    public init(
        id: String, name: String, nameIgnorePrefix: String? = nil, description: String? = nil,
        sequence: String? = nil, libraryId: String? = nil, addedAt: Int? = nil, updatedAt: Int? = nil,
        books: [LibraryItem]? = nil, totalDuration: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.nameIgnorePrefix = nameIgnorePrefix
        self.description = description
        self.sequence = sequence
        self.libraryId = libraryId
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.books = books
        self.totalDuration = totalDuration
    }

    enum CodingKeys: String, CodingKey {
        case id, name, nameIgnorePrefix, description, sequence, libraryId, addedAt, updatedAt, books, totalDuration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        nameIgnorePrefix = try container.decodeIfPresent(String.self, forKey: .nameIgnorePrefix)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        sequence = try container.decodeIfPresent(String.self, forKey: .sequence)
        libraryId = try container.decodeIfPresent(String.self, forKey: .libraryId)
        addedAt = try container.decodeIfPresent(Int.self, forKey: .addedAt)
        updatedAt = try container.decodeIfPresent(Int.self, forKey: .updatedAt)
        books = try container.decodeLossyArrayIfPresent(LibraryItem.self, forKey: .books)
        totalDuration = try container.decodeIfPresent(Double.self, forKey: .totalDuration)
    }
}
