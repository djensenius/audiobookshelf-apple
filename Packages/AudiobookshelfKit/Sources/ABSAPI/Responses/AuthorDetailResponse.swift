import ABSCore
import Foundation

/// `GET /api/authors/:id?include=items,series`. Author metadata is flat on the wire.
public struct AuthorDetailResponse: Decodable, Sendable, Hashable {
    public let author: Author
    /// Canonical minified items, including books that belong to no series.
    public let libraryItems: [LibraryItem]
    public let series: [AuthorSeries]

    public init(author: Author, libraryItems: [LibraryItem] = [], series: [AuthorSeries] = []) {
        self.author = author
        self.libraryItems = libraryItems
        self.series = series
    }

    enum CodingKeys: String, CodingKey {
        case libraryItems, series
    }

    public init(from decoder: any Decoder) throws {
        author = try Author(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        libraryItems = try container.decodeLossyArrayIfPresent(LibraryItem.self, forKey: .libraryItems) ?? []
        series = try container.decodeLossyArrayIfPresent(AuthorSeries.self, forKey: .series) ?? []
    }
}

/// An author's series group. Unlike `ABSCore.Series`, this endpoint sends `items`, not `books`.
public struct AuthorSeries: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// Associations in server sequence order; resolve item details from `libraryItems` by id.
    public let items: [AuthorSeriesItem]

    public init(id: String, name: String, items: [AuthorSeriesItem] = []) {
        self.id = id
        self.name = name
        self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case id, name, items
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        items = try container.decodeLossyArrayIfPresent(AuthorSeriesItem.self, forKey: .items) ?? []
    }
}

/// A reference to a canonical `libraryItems` entry, plus its series-specific metadata.
///
/// Both verified servers repeat the minified item here, but replace `media.metadata.series`
/// with a single object carrying the sequence. Decoding that copy as `LibraryItem` would
/// discard valid books because `BookMetadata.series` expects an array. Keep the association
/// separately rather than duplicating the core item/media models or changing their wire format.
public struct AuthorSeriesItem: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let libraryId: String
    public let series: Series?

    public init(id: String, libraryId: String, series: Series? = nil) {
        self.id = id
        self.libraryId = libraryId
        self.series = series
    }

    enum CodingKeys: String, CodingKey {
        case id, libraryId, media
    }

    private struct Media: Decodable {
        struct Metadata: Decodable {
            let series: Series?
        }
        let metadata: Metadata?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        libraryId = try container.decode(String.self, forKey: .libraryId)
        series = try container.decodeIfPresent(Media.self, forKey: .media)?.metadata?.series
    }
}
