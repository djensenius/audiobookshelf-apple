import Foundation

/// A bookmark in an audiobook, from ``User/bookmarks``. The server identifies a bookmark by
/// `libraryItemId` and `time` (for example `DELETE /api/me/item/:id/bookmark/:time`).
public struct AudioBookmark: Sendable, Hashable, Codable {
    public var libraryItemId: String
    public var title: String
    /// Seconds from the start of the item.
    public var time: Double
    /// Epoch milliseconds.
    public var createdAt: Int?

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
        time = try container.decode(Double.self, forKey: .time)
        createdAt = try container.decodeIfPresent(Int.self, forKey: .createdAt)
    }
}
