import ABSCore
import Foundation

/// `GET /api/me/listening-stats`, with the recent sessions also decoded as
/// ``ListeningSessionSummary`` values. ``ListeningStats/recentSessions`` drops sessions that
/// aren't full ``PlaybackSession``s, such as old rows with a null `libraryItemId`; the summaries
/// keep every session with an `id`.
public struct ListeningStatsResponse: Decodable, Sendable, Hashable {
    public var stats: ListeningStats
    /// The recent sessions in server order, including those without a library item.
    public var recentSessions: [ListeningSessionSummary]

    public init(stats: ListeningStats, recentSessions: [ListeningSessionSummary]? = nil) {
        self.stats = stats
        self.recentSessions = recentSessions ?? stats.recentSessions.map(ListeningSessionSummary.init)
    }

    enum CodingKeys: String, CodingKey {
        case recentSessions
    }

    public init(from decoder: any Decoder) throws {
        stats = try ListeningStats(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recentSessions =
            (try? container.decodeLossyArrayIfPresent(ListeningSessionSummary.self, forKey: .recentSessions)) ?? []
    }
}

/// The fields of a recent listening session the stats page shows. Only `id` is required.
public struct ListeningSessionSummary: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    /// `nil` when the session lost its item (old rows have `null`) or the value is empty.
    public var libraryItemId: String?
    public var title: String?
    /// Seconds; accepts a numeric string, as old rows can have.
    public var timeListening: Double
    /// Epoch milliseconds.
    public var updatedAt: Int?

    public init(
        id: String, libraryItemId: String? = nil, title: String? = nil, timeListening: Double = 0,
        updatedAt: Int? = nil
    ) {
        self.id = id
        self.libraryItemId = libraryItemId
        self.title = title
        self.timeListening = timeListening
        self.updatedAt = updatedAt
    }

    public init(_ session: PlaybackSession) {
        self.init(
            id: session.id, libraryItemId: session.libraryItemId,
            title: session.mediaMetadata?.title
                ?? session.displayTitle, timeListening: session.timeListening, updatedAt: session.updatedAt)
        if libraryItemId?.isEmpty == true { libraryItemId = nil }
    }

    enum CodingKeys: String, CodingKey {
        case id, libraryItemId, mediaMetadata, displayTitle, timeListening, updatedAt
    }

    private struct Metadata: Decodable {
        let title: String?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        libraryItemId = (try? container.decodeIfPresent(String.self, forKey: .libraryItemId)).flatMap { $0 }
        if libraryItemId?.isEmpty == true { libraryItemId = nil }
        let metadataTitle = (try? container.decodeIfPresent(Metadata.self, forKey: .mediaMetadata))?.flatMap(\.title)
        let displayTitle = (try? container.decodeIfPresent(String.self, forKey: .displayTitle)).flatMap { $0 }
        title = metadataTitle ?? displayTitle
        timeListening = Self.lenientDouble(container, .timeListening) ?? 0
        // Epoch milliseconds stay far below this; it guards the integer conversion.
        updatedAt = Self.lenientDouble(container, .updatedAt).flatMap { abs($0) < 9e15 ? Int($0) : nil }
    }

    /// A finite number or numeric string at `key`, else `nil`.
    private static func lenientDouble(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        let value: Double?
        if let number = try? container.decodeIfPresent(Double.self, forKey: key) {
            value = number
        } else if let string = try? container.decodeIfPresent(String.self, forKey: key) {
            value = Double(string.trimmingCharacters(in: .whitespaces))
        } else {
            value = nil
        }
        return value.flatMap { $0.isFinite ? $0 : nil }
    }
}
