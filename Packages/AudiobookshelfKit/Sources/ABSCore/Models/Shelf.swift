import Foundation

/// The kind of entities a personalized shelf holds.
public enum ShelfType: Sendable, Hashable, Codable, RawRepresentable {
    case book
    case podcast
    case episode
    case series
    case authors
    /// A type this client doesn't know; the server's value is kept.
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "book": self = .book
        case "podcast": self = .podcast
        case "episode": self = .episode
        case "series": self = .series
        case "authors": self = .authors
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .book: "book"
        case .podcast: "podcast"
        case .episode: "episode"
        case .series: "series"
        case .authors: "authors"
        case .unknown(let value): value
        }
    }
}

/// A shelf's entities, whose shape depends on the shelf's `type`. Entities that fail to decode
/// are skipped.
public enum ShelfEntities: Sendable, Hashable, Encodable {
    /// Minified library items (for `book`, `podcast`, and `episode` shelves; episode shelves
    /// set `recentEpisode`).
    case libraryItems([LibraryItem])
    case series([Series])
    case authors([Author])
    /// Entities of a shelf type this client doesn't know.
    case unknown

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .libraryItems(let items): try container.encode(items)
        case .series(let series): try container.encode(series)
        case .authors(let authors): try container.encode(authors)
        case .unknown: try container.encode([String]())
        }
    }
}

/// A shelf from `GET /api/libraries/:id/personalized`.
public struct Shelf: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let label: String
    /// Localization key for `label`, for example `LabelContinueListening`.
    public let labelStringKey: String?
    public let type: ShelfType
    public let category: String?
    public let total: Int?
    public let entities: ShelfEntities

    public init(
        id: String, label: String, labelStringKey: String? = nil, type: ShelfType, category: String? = nil,
        total: Int? = nil, entities: ShelfEntities
    ) {
        self.id = id
        self.label = label
        self.labelStringKey = labelStringKey
        self.type = type
        self.category = category
        self.total = total
        self.entities = entities
    }

    enum CodingKeys: String, CodingKey {
        case id, label, labelStringKey, type, category, total, entities
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        labelStringKey = try container.decodeIfPresent(String.self, forKey: .labelStringKey)
        type = try container.decode(ShelfType.self, forKey: .type)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        total = try container.decodeIfPresent(Int.self, forKey: .total)
        switch type {
        case .book, .podcast, .episode:
            entities = .libraryItems(try container.decodeLossyArrayIfPresent(LibraryItem.self, forKey: .entities) ?? [])
        case .series:
            entities = .series(try container.decodeLossyArrayIfPresent(Series.self, forKey: .entities) ?? [])
        case .authors:
            entities = .authors(try container.decodeLossyArrayIfPresent(Author.self, forKey: .entities) ?? [])
        case .unknown:
            entities = .unknown
        }
    }
}
