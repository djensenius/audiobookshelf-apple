import ABSAPI
import ABSCore
import Foundation
import Testing

// Actual POST /api/collections responses from owned disposable official images, 2026-11-10.
// Both revision labels and /status versions verified; digests/pins recorded in server-contracts.md.
// Two existing synthetic seeded books, one mutation per version, explicitly deleted before teardown.
// Stable synthetic IDs/dates/paths; trimmed filesystem/audio-probe fields, retaining metadata,
// chapters and expanded tracks. Original sanitized captures remain in the worktree's .build.
func collectionWriteFixture(_ version: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: "collection-writes-\(version)", withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct CollectionResponseTests {
    @Test(arguments: ["2.26.0", "2.37.2"])
    func actualExpandedResponsePreservesRawMembership(version: String) throws {
        let data = try collectionWriteFixture(version)
        let value = try JSONDecoder().decode(LibraryCollection.self, from: data)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rawBooks = try #require(raw["books"] as? [[String: Any]])
        #expect(value.id == "collection-fixture")
        #expect(value.libraryId == "library-books")
        #expect(value.name == "Captured collection")
        #expect(value.description == "Synthetic fixture")
        #expect(value.userId == nil)
        #expect(value.createdAt == 1_700_000_000_000)
        #expect(value.lastUpdate == 1_700_000_000_000)
        #expect(value.books?.count == rawBooks.count)
        #expect(value.books?.map(\.id) == rawBooks.compactMap { $0["id"] as? String })
        #expect(value.books?.map(\.id) == ["item-tale", "item-single"])
        let books = try #require(value.books)
        #expect(books.allSatisfy { $0.id != $0.book?.id })
        #expect(books.map(\.book?.metadata.title) == ["The Synthetic Tale", "Single File Tale"])
        #expect(books.first?.book?.duration == (version == "2.26.0" ? 50.184 : 50))
        #expect(books.last?.book?.duration == 40)
        #expect(books.map(\.book?.tracks?.count) == [2, 1])
        #expect(books.map(\.book?.chapters?.count) == [2, 3])
        #expect(try JSONDecoder().decode(LibraryCollection.self, from: JSONEncoder().encode(value)) == value)
    }
}
