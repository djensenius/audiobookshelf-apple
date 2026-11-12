import ABSCore

/// What an RSS feed can be opened for, and its ID; the item, collection or series route.
public struct RssFeedTarget: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case item, collection, series
    }

    public let kind: Kind
    /// The library item, collection or series ID.
    public let id: String

    public init(_ kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }
}

/// Opens a feed (legacy `RssFeedModal.vue`). The server rejects a slug another feed uses; empty
/// owner fields are stored as no owner.
public struct RssFeedOpenRequest: Encodable, Sendable, Hashable {
    /// The address the feed's links are built on, normally the one the client connects to.
    public let serverAddress: String
    public let slug: String
    public let metadataDetails: MetadataDetails

    public struct MetadataDetails: Encodable, Sendable, Hashable {
        public let preventIndexing: Bool
        public let ownerName: String
        public let ownerEmail: String

        public init(preventIndexing: Bool, ownerName: String, ownerEmail: String) {
            self.preventIndexing = preventIndexing
            self.ownerName = ownerName
            self.ownerEmail = ownerEmail
        }
    }

    public init(serverAddress: String, slug: String, metadataDetails: MetadataDetails) {
        self.serverAddress = serverAddress
        self.slug = slug
        self.metadataDetails = metadataDetails
    }
}

/// `{ feed }`, the reply to opening a feed.
public struct RssFeedOpenResponse: Decodable, Sendable, Hashable {
    public let feed: RssFeed
}

/// The `rssFeed` of an item, collection or series fetched with `include=rssfeed`; the rest of the
/// response is ignored. Missing or `null` means no feed is open.
public struct RssFeedLookup: Decodable, Sendable, Hashable {
    public let rssFeed: RssFeed?
}
