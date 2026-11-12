import ABSCore
import Foundation

/// `GET /api/me` reduced to the user's full progress list, to seed the library's progress cache.
/// A malformed row is skipped and counted in ``skippedRows``, but a missing `mediaProgress`, or
/// one that isn't a list, throws: seeding replaces the cache, so an absent list must never read
/// as "no progress".
public struct UserProgressResponse: Decodable, Sendable, Hashable {
    /// In server order.
    public var mediaProgress: [MediaProgress]
    /// The rows that couldn't be decoded. When any were, ``mediaProgress`` is incomplete, and
    /// an item missing from it may still have progress on the server.
    public var skippedRows: Int

    public init(mediaProgress: [MediaProgress], skippedRows: Int = 0) {
        self.mediaProgress = mediaProgress
        self.skippedRows = skippedRows
    }

    enum CodingKeys: String, CodingKey {
        case mediaProgress
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var rows = try container.nestedUnkeyedContainer(forKey: .mediaProgress)
        var progress: [MediaProgress] = []
        var skipped = 0
        while !rows.isAtEnd {
            if let row = try? rows.decode(MediaProgress.self) {
                progress.append(row)
            } else {
                // A failed decode doesn't advance the container; consume the row.
                _ = try rows.decode(SkippedRow.self)
                skipped += 1
            }
        }
        mediaProgress = progress
        skippedRows = skipped
    }

    private struct SkippedRow: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}
