import ABSCore
import Foundation

/// One page of a library list (`/api/libraries/:id/{items|series|collections|playlists}`).
///
/// Results that fail to decode are skipped. The server echoes `limit` and `page` from the query
/// string, so they may arrive as strings.
///
/// `Element` only has to be `Decodable` to decode a page; a mapped page of display values
/// (see `LibraryBrowseModel`) needs no decoding.
public struct PagedResults<Element: Sendable>: Sendable {
    public let results: [Element]
    /// The number of rows the server sent, including those skipped in ``results``. Use it to
    /// page: a page of malformed rows is still a full page.
    public let rawCount: Int
    /// Missing when the server lists a series' sub-series with `collapseseries=1`.
    public let total: Int?
    /// `0` means unlimited.
    public let limit: Int
    public let page: Int

    /// `rawCount` defaults to the number of `results`.
    public init(results: [Element], total: Int?, limit: Int, page: Int, rawCount: Int? = nil) {
        self.results = results
        self.rawCount = rawCount ?? results.count
        self.total = total
        self.limit = limit
        self.page = page
    }

    /// The page with each result replaced by `transform`'s value; paging fields are kept.
    public func map<Mapped: Sendable>(_ transform: (Element) -> Mapped) -> PagedResults<Mapped> {
        PagedResults<Mapped>(
            results: results.map(transform), total: total, limit: limit, page: page, rawCount: rawCount)
    }
}

extension PagedResults: Decodable where Element: Decodable {
    enum CodingKeys: String, CodingKey {
        case results, total, limit, page
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        results = try container.decodeLossyArrayIfPresent(Element.self, forKey: .results) ?? []
        rawCount = (try? container.nestedUnkeyedContainer(forKey: .results))?.count ?? results.count
        total = try container.decodeLenientIntIfPresent(forKey: .total)
        limit = try container.decodeLenientIntIfPresent(forKey: .limit) ?? 0
        page = try container.decodeLenientIntIfPresent(forKey: .page) ?? 0
    }
}

extension PagedResults: Equatable where Element: Equatable {}

extension KeyedDecodingContainer {
    /// Decodes an integer sent as a number or a numeric string; other values decode as `nil`.
    func decodeLenientIntIfPresent(forKey key: Key) throws -> Int? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) { return Int(value) }
        return nil
    }
}
