import ABSCore
import Foundation

/// `GET /api/me` reduced to the user's full progress list, to seed the library's progress cache.
/// A malformed row is skipped, but a missing `mediaProgress`, or one that isn't a list, throws:
/// seeding replaces the cache, so an absent list must never read as "no progress".
public struct UserProgressResponse: Decodable, Sendable, Hashable {
    /// In server order.
    public var mediaProgress: [MediaProgress]

    public init(mediaProgress: [MediaProgress]) {
        self.mediaProgress = mediaProgress
    }

    enum CodingKeys: String, CodingKey {
        case mediaProgress
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mediaProgress = try container.decode(LossyArray<MediaProgress>.self, forKey: .mediaProgress).elements
    }
}
