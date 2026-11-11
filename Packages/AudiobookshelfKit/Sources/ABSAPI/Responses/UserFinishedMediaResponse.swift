import ABSCore
import Foundation

/// `GET /api/me` reduced to the media of each progress row and whether it is finished. Rows
/// without a usable item ID are skipped, and a missing or malformed `isFinished` reads as not
/// finished; every other field of the user is ignored.
public struct UserFinishedMediaResponse: Decodable, Sendable, Hashable {
    public struct Entry: Decodable, Sendable, Hashable {
        public var libraryItemId: String
        public var episodeId: String?
        public var isFinished: Bool

        public init(libraryItemId: String, episodeId: String? = nil, isFinished: Bool) {
            self.libraryItemId = libraryItemId
            self.episodeId = episodeId
            self.isFinished = isFinished
        }

        enum CodingKeys: String, CodingKey {
            case libraryItemId, episodeId, isFinished
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            libraryItemId = try container.decode(String.self, forKey: .libraryItemId)
            episodeId = (try? container.decodeIfPresent(String.self, forKey: .episodeId)) ?? nil
            isFinished = (try? container.decodeIfPresent(Bool.self, forKey: .isFinished)) ?? false
        }
    }

    /// In server order.
    public var mediaProgress: [Entry]

    public init(mediaProgress: [Entry]) {
        self.mediaProgress = mediaProgress
    }

    enum CodingKeys: String, CodingKey {
        case mediaProgress
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mediaProgress = (try? container.decodeLossyArrayIfPresent(Entry.self, forKey: .mediaProgress)) ?? []
    }
}
