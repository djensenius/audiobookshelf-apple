import ABSCore
import Foundation

/// `GET /api/me` reduced to the media of each progress row, whether it is finished and when. Rows
/// without a usable item ID are skipped, a missing or malformed `isFinished` reads as not
/// finished, a missing or malformed `finishedAt` as unknown, and a `mediaProgress` that isn't a
/// list throws; every other field is ignored.
public struct UserFinishedMediaResponse: Decodable, Sendable, Hashable {
    public struct Entry: Decodable, Sendable, Hashable {
        public var libraryItemId: String
        public var episodeId: String?
        public var isFinished: Bool
        /// When the server marked it finished, in epoch milliseconds.
        public var finishedAt: Int?

        public init(libraryItemId: String, episodeId: String? = nil, isFinished: Bool, finishedAt: Int? = nil) {
            self.libraryItemId = libraryItemId
            self.episodeId = episodeId
            self.isFinished = isFinished
            self.finishedAt = finishedAt
        }

        enum CodingKeys: String, CodingKey {
            case libraryItemId, episodeId, isFinished, finishedAt
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            libraryItemId = try container.decode(String.self, forKey: .libraryItemId)
            episodeId = (try? container.decodeIfPresent(String.self, forKey: .episodeId)) ?? nil
            isFinished = (try? container.decodeIfPresent(Bool.self, forKey: .isFinished)) ?? false
            finishedAt = (try? container.decodeIfPresent(Int.self, forKey: .finishedAt)) ?? nil
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
        // A malformed row is skipped, but a malformed list throws: unknown isn't "none finished".
        mediaProgress = try container.decodeLossyArrayIfPresent(Entry.self, forKey: .mediaProgress) ?? []
    }
}
