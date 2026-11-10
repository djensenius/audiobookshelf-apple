import Foundation
import Testing

@testable import ABSAPI

/// Expected values were produced with the legacy app's encoding:
/// `encodeURIComponent(Buffer.from(value).toString('base64'))` (plugins/init.client.js `$encode`)
/// and `URLSearchParams.toString()` as used by `components/bookshelf/LazyBookshelf.vue`.
@Suite struct LibraryQueryTests {
    private let base = URL(string: "https://abs.example/abs")!

    @Test(arguments: [
        (LibraryFilter.noSeries, "series.bm8tc2VyaWVz"),
        (LibraryFilter.authors(id: "aut_z9x1y2"), "authors.YXV0X3o5eDF5Mg%3D%3D"),
        (LibraryFilter.genres("Science Fiction & Fantasy"), "genres.U2NpZW5jZSBGaWN0aW9uICYgRmFudGFzeQ%3D%3D"),
        (LibraryFilter.narrators("Zoë Ünïcode"), "narrators.Wm%2FDqyDDnG7Dr2NvZGU%3D"),
        (LibraryFilter.tags("a?>b"), "tags.YT8%2BYg%3D%3D"),
        (LibraryFilter.progress("finished"), "progress.ZmluaXNoZWQ%3D"),
        (LibraryFilter.issues, "issues"),
        (LibraryFilter.feedOpen, "feed-open"),
    ])
    func filterValueMatchesLegacyEncode(filter: LibraryFilter, expected: String) {
        #expect(filter.queryValue == expected)
    }

    @Test(arguments: [
        (
            LibraryFilter.authors(id: "aut_z9x1y2"),
            "filter=authors.YXV0X3o5eDF5Mg%253D%253D&sort=media.metadata.title&desc=1&collapseseries=1"
        ),
        (
            LibraryFilter.narrators("Zoë Ünïcode"),
            "filter=narrators.Wm%252FDqyDDnG7Dr2NvZGU%253D&sort=media.metadata.title&desc=1&collapseseries=1"
        ),
        (
            LibraryFilter.tags("a?>b"),
            "filter=tags.YT8%252BYg%253D%253D&sort=media.metadata.title&desc=1&collapseseries=1"
        ),
    ])
    func wireQueryMatchesLazyBookshelf(filter: LibraryFilter, expected: String) throws {
        let query = LibraryQuery(sort: "media.metadata.title", descending: true, filter: filter, collapseSeries: true)
        let url = try APIClient.url(base: base, path: "/api/libraries/lib1/items", query: query.queryItems)
        #expect(url.query(percentEncoded: true) == expected)
    }

    @Test func emptyQueryHasNoItems() {
        #expect(LibraryQuery().queryItems.isEmpty)
    }

    @Test func descIsSentOnlyWithSort() {
        #expect(LibraryQuery(descending: true).queryItems.isEmpty)
        let items = LibraryQuery(sort: "name").queryItems
        #expect(items == [URLQueryItem(name: "sort", value: "name"), URLQueryItem(name: "desc", value: "0")])
    }

    @Test func pagingFollowsFilterAndSort() {
        let query = LibraryQuery(sort: "addedAt", descending: true, filter: .issues, page: 2, limit: 50)
        #expect(
            query.queryItems.map { "\($0.name)=\($0.value ?? "")" } == [
                "filter=issues", "sort=addedAt", "desc=1", "limit=50", "page=2",
            ])
    }
}
