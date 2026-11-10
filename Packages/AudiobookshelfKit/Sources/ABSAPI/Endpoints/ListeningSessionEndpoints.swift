import ABSCore
import Foundation

/// A stored listening session, as `GET /api/me/item/listening-sessions/…` returns it. Only the
/// fields the ADR 0007 `/close` reconciliation reads are decoded.
public struct ListeningSessionRecord: Decodable, Sendable, Hashable {
    public let id: String
    /// Seconds; the server stores a session only once this is above 0.
    public let timeListening: Double
    /// Seconds.
    public let currentTime: Double
    /// Epoch milliseconds.
    public let updatedAt: Int?

    public init(id: String, timeListening: Double, currentTime: Double, updatedAt: Int? = nil) {
        self.id = id
        self.timeListening = timeListening
        self.currentTime = currentTime
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, timeListening, currentTime, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        timeListening = try container.decodeIfPresent(Double.self, forKey: .timeListening) ?? 0
        currentTime = try container.decodeIfPresent(Double.self, forKey: .currentTime) ?? 0
        updatedAt = try container.decodeIfPresent(Int.self, forKey: .updatedAt)
    }
}

/// One page of the user's stored sessions for an item or episode, newest first
/// (`MeController.getItemListeningSessions`). Sessions that fail to decode are skipped.
public struct ListeningSessionsPage: Decodable, Sendable, Hashable {
    public let sessions: [ListeningSessionRecord]
    public let total: Int
    public let numPages: Int
    public let page: Int
    public let itemsPerPage: Int

    enum CodingKeys: String, CodingKey {
        case sessions, total, numPages, page, itemsPerPage
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decodeLossyArrayIfPresent(ListeningSessionRecord.self, forKey: .sessions) ?? []
        total = try container.decodeLenientIntIfPresent(forKey: .total) ?? sessions.count
        numPages = try container.decodeLenientIntIfPresent(forKey: .numPages) ?? 1
        page = try container.decodeLenientIntIfPresent(forKey: .page) ?? 0
        itemsPerPage = try container.decodeLenientIntIfPresent(forKey: .itemsPerPage) ?? sessions.count
    }
}

extension SessionEndpoints {
    /// `GET /api/me/item/listening-sessions/:libraryItemId[/:episodeId]`: the user's stored
    /// (closed or synced) sessions for the media, newest first. `page` is zero-based; the server
    /// defaults to 10 per page. Throws ``APIError/notFound`` when the item or episode doesn't
    /// exist. Used to reconcile an unacknowledged `/close` (ADR 0007).
    public static func listeningSessions(
        itemID: String, episodeID: String? = nil, page: Int = 0, itemsPerPage: Int = 10
    ) -> Endpoint<ListeningSessionsPage> {
        var path = "/api/me/item/listening-sessions/\(pathSegment(itemID))"
        if let episodeID, !episodeID.isEmpty { path += "/\(pathSegment(episodeID))" }
        return Endpoint(
            .get, path,
            query: [
                URLQueryItem(name: "itemsPerPage", value: String(itemsPerPage)),
                URLQueryItem(name: "page", value: String(page)),
            ])
    }
}
