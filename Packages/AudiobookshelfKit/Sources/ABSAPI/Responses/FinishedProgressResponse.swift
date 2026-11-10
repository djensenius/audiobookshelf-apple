import ABSCore
import Foundation

/// `GET /api/me`, decoded only for what the stats page's Items Finished tile needs.
/// ``User/mediaProgress`` drops rows that aren't full ``MediaProgress`` values, such as old rows
/// with a null `libraryItemId`; the legacy page counted every finished row, so this keeps any
/// row with an `isFinished` flag.
public struct FinishedProgressResponse: Decodable, Sendable, Hashable {
    /// The `isFinished` flag of each progress row, in server order.
    public var finished: [Bool]

    public init(finished: [Bool]) {
        self.finished = finished
    }

    /// The number of finished rows, finished podcast episodes included.
    public var finishedCount: Int { finished.count(where: { $0 }) }

    enum CodingKeys: String, CodingKey {
        case mediaProgress
    }

    private struct Row: Decodable {
        let isFinished: Bool
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        finished =
            ((try? container.decodeLossyArrayIfPresent(Row.self, forKey: .mediaProgress)) ?? []).map(\.isFinished)
    }
}
