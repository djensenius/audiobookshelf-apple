import Foundation

/// A bookmark in an audiobook, from ``User/bookmarks``. The server identifies a bookmark by
/// `libraryItemId` and `time` (for example `DELETE /api/me/item/:id/bookmark/:time`).
public struct AudioBookmark: Sendable, Hashable, Codable, Identifiable {
    public var libraryItemId: String
    public var title: String
    /// Seconds from the start of the item.
    public var time: Double
    /// Epoch milliseconds.
    public var createdAt: Int?

    /// `libraryItemId-time`, matching how the server identifies a bookmark.
    public var id: String {
        "\(libraryItemId)-\(time)"
    }

    public init(libraryItemId: String, title: String = "", time: Double, createdAt: Int? = nil) {
        self.libraryItemId = libraryItemId
        self.title = title
        self.time = time
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case libraryItemId, title, time, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        libraryItemId = try container.decode(String.self, forKey: .libraryItemId)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        // The server stores `time` as sent, so it can be a numeric string.
        guard let time = container.decodeLenientDouble(forKey: .time) else {
            throw DecodingError.dataCorruptedError(
                forKey: .time, in: container, debugDescription: "Expected a number or numeric string")
        }
        self.time = time
        createdAt = try container.decodeIfPresent(Int.self, forKey: .createdAt)
    }
}
