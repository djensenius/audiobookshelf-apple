import ABSCore
import Foundation

/// `GET /api/me` reduced to the user's bookmarks; every other field is ignored. A missing
/// `bookmarks` decodes as empty and malformed entries are skipped, but a `bookmarks` that isn't a
/// list throws, so a broken payload can't read as "no bookmarks".
public struct UserBookmarksResponse: Decodable, Sendable, Hashable {
    /// In server order.
    public var bookmarks: [AudioBookmark]

    public init(bookmarks: [AudioBookmark]) {
        self.bookmarks = bookmarks
    }

    enum CodingKeys: String, CodingKey {
        case bookmarks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookmarks = try container.decodeLossyArrayIfPresent(AudioBookmark.self, forKey: .bookmarks) ?? []
    }
}
