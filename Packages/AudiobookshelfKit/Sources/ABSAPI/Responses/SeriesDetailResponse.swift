import ABSCore
import Foundation

/// `GET /api/series/:id?include=progress`. Series metadata is flat on the wire, not nested.
public struct SeriesDetailResponse: Decodable, Sendable, Hashable {
    public let series: Series
    /// Nil when not requested (or returned as null); not equivalent to unfinished progress.
    public let progress: SeriesProgress?

    public init(series: Series, progress: SeriesProgress? = nil) {
        self.series = series
        self.progress = progress
    }

    enum CodingKeys: String, CodingKey {
        case progress
    }

    public init(from decoder: any Decoder) throws {
        series = try Series(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        progress = try container.decodeIfPresent(SeriesProgress.self, forKey: .progress)
    }
}

/// Aggregate progress for the caller's accessible books in a series.
public struct SeriesProgress: Decodable, Sendable, Hashable {
    /// Library-item IDs, not the book media IDs the server uses to look up progress.
    public let libraryItemIds: [String]
    public let libraryItemIdsFinished: [String]
    /// The server's stored-finished result. Never inferred from the lossy ID arrays.
    public let isFinished: Bool

    public init(libraryItemIds: [String], libraryItemIdsFinished: [String], isFinished: Bool) {
        self.libraryItemIds = libraryItemIds
        self.libraryItemIdsFinished = libraryItemIdsFinished
        self.isFinished = isFinished
    }

    enum CodingKeys: String, CodingKey {
        case libraryItemIds, libraryItemIdsFinished, isFinished
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // All canonical fields are required. Only individual array elements are lossy:
        // a missing/null field or a changed container shape must fail, not look unfinished.
        libraryItemIds = try container.decode(LossyArray<String>.self, forKey: .libraryItemIds).elements
        libraryItemIdsFinished = try container.decode(
            LossyArray<String>.self, forKey: .libraryItemIdsFinished
        ).elements
        isFinished = try container.decode(Bool.self, forKey: .isFinished)
    }
}
