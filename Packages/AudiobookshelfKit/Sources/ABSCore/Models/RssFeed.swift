import Foundation

/// An open RSS feed (server `Feed.toOldJSONMinified`). The full `toOldJSON`, sent by a
/// collection's `include=rssfeed`, has more fields, which are ignored.
public struct RssFeed: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    /// `libraryItem`, `collection`, `series` or `playlist`.
    public let entityType: String
    public let entityId: String
    /// Relative to the server address the feed was opened with, such as `/feed/my-slug`.
    public let feedUrl: String
    public let meta: Meta?

    public struct Meta: Sendable, Hashable, Codable {
        public let title: String?
        public let description: String?
        public let preventIndexing: Bool?
        public let ownerName: String?
        public let ownerEmail: String?

        public init(
            title: String? = nil, description: String? = nil, preventIndexing: Bool? = nil, ownerName: String? = nil,
            ownerEmail: String? = nil
        ) {
            self.title = title
            self.description = description
            self.preventIndexing = preventIndexing
            self.ownerName = ownerName
            self.ownerEmail = ownerEmail
        }
    }

    public init(id: String, entityType: String, entityId: String, feedUrl: String, meta: Meta? = nil) {
        self.id = id
        self.entityType = entityType
        self.entityId = entityId
        self.feedUrl = feedUrl
        self.meta = meta
    }

    /// The feed's address on `server`: `feedUrl` appended to it, or `feedUrl` itself if it's absolute.
    public func url(on server: URL) -> URL? {
        if let absolute = URL(string: feedUrl), absolute.scheme != nil { return absolute }
        var base = server.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let path = feedUrl.hasPrefix("/") ? feedUrl : "/" + feedUrl
        return URL(string: base + path)
    }
}
