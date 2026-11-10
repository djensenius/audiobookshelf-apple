import Foundation

/// A library list filter: a group, optionally with a value, for example `authors.<id>`.
///
/// Values are encoded like the legacy `$encode` helper (`encodeURIComponent` of the UTF-8
/// Base64): the server decodes them with `decodeURIComponent` and then Base64.
public struct LibraryFilter: Sendable, Hashable {
    public var group: String
    /// The unencoded value (an ID, a name, or for example `finished` for `progress`).
    public var value: String?

    public init(group: String, value: String? = nil) {
        self.group = group
        self.value = value
    }

    public static func genres(_ genre: String) -> Self { Self(group: "genres", value: genre) }
    public static func tags(_ tag: String) -> Self { Self(group: "tags", value: tag) }
    public static func series(id: String) -> Self { Self(group: "series", value: id) }
    /// Books in no series.
    public static let noSeries = Self(group: "series", value: "no-series")
    public static func authors(id: String) -> Self { Self(group: "authors", value: id) }
    public static func narrators(_ narrator: String) -> Self { Self(group: "narrators", value: narrator) }
    public static func languages(_ language: String) -> Self { Self(group: "languages", value: language) }
    /// `finished`, `in-progress`, `not-started`, or `not-finished`.
    public static func progress(_ state: String) -> Self { Self(group: "progress", value: state) }
    /// `ebook` or `supplementary`.
    public static func ebooks(_ kind: String) -> Self { Self(group: "ebooks", value: kind) }
    public static let issues = Self(group: "issues")
    public static let feedOpen = Self(group: "feed-open")
    public static let explicit = Self(group: "explicit")

    /// The `filter` query value, before URL query encoding.
    public var queryValue: String {
        guard let value else { return group }
        return "\(group).\(Self.encode(value))"
    }

    /// `encodeURIComponent(Buffer.from(value).toString('base64'))`.
    static func encode(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "/", with: "%2F")
            .replacingOccurrences(of: "=", with: "%3D")
    }
}

/// Sort, filter, and paging options for the paged library lists.
public struct LibraryQuery: Sendable, Hashable {
    /// A sort key, for example `media.metadata.title`, `addedAt`, or `name` for series.
    public var sort: String?
    /// Sent as `desc`, only together with `sort`.
    public var descending: Bool
    public var filter: LibraryFilter?
    /// Zero-based.
    public var page: Int?
    public var limit: Int?
    /// Shows each series as one item (`collapseseries=1`).
    public var collapseSeries: Bool

    public init(
        sort: String? = nil, descending: Bool = false, filter: LibraryFilter? = nil, page: Int? = nil,
        limit: Int? = nil, collapseSeries: Bool = false
    ) {
        self.sort = sort
        self.descending = descending
        self.filter = filter
        self.page = page
        self.limit = limit
        self.collapseSeries = collapseSeries
    }

    /// The query items in the legacy bookshelf's order.
    public var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let filter { items.append(URLQueryItem(name: "filter", value: filter.queryValue)) }
        if let sort {
            items.append(URLQueryItem(name: "sort", value: sort))
            items.append(URLQueryItem(name: "desc", value: descending ? "1" : "0"))
        }
        if collapseSeries { items.append(URLQueryItem(name: "collapseseries", value: "1")) }
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let page { items.append(URLQueryItem(name: "page", value: String(page))) }
        return items
    }
}
