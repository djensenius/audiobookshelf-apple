import ABSAPI
import ABSCore
import Foundation
import Testing

// Captured from owned disposable ghcr.io/advplyr/audiobookshelf servers, 2026-11-10.
// Canonical source: advplyr/audiobookshelf, v2.26.0 @ 264ae928a9c1af620487488110eec816b14e23ec
// and v2.37.2 @ edb1f7efc92ecacdef51aafb4d9d5054ce10604f.
// Image digests: 2.26.0 sha256:16685fbba37a21d403f5390b907d286e15b3086d26527269b4ad785f71f571e5
//                2.37.2 sha256:b897c33f05972fb1bf484f7487bc878fa91ec8691335c1db6e2929c3a7658efa
// Scanned one generated 30 s MP3 (artist Author Fixture, album Author Tale), then PATCHed
// /api/items/:id/media with {"metadata":{"series":[{"name":"Fixture Cycle","sequence":"2.5"}]}}.
// Request verified in both pinned LibraryItemController.updateMedia / Book.updateSeriesFromRequest;
// response in AuthorController.findOne. No shared harness seeds were changed.
// GET /api/authors/:id?include=items,series captured without trimming keys. IDs, inode,
// paths and timestamps replaced with stable synthetic values; no user or auth data retained.
func authorDetailFixture(_ version: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: "author-detail-\(version)", withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct AuthorDetailResponseTests {
    private func decode(_ json: String) throws -> AuthorDetailResponse {
        try JSONDecoder().decode(AuthorDetailResponse.self, from: Data(json.utf8))
    }

    @Test(arguments: ["2.26.0", "2.37.2"])
    func verifiedRealShapesPreserveAllAssociations(version: String) throws {
        let data = try authorDetailFixture(version)
        let response = try JSONDecoder().decode(AuthorDetailResponse.self, from: data)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(response.author.id == "author-fixture")
        #expect(response.author.name == "Author Fixture")
        #expect(response.author.libraryId == "library-fixture")
        #expect(response.author.addedAt == 1_700_000_000_000)
        #expect(response.author.updatedAt == 1_700_000_000_000)
        #expect(response.author.asin == nil)
        #expect(response.author.description == nil)
        #expect(response.author.imagePath == nil)
        #expect(response.libraryItems.count == (raw["libraryItems"] as? [Any])?.count)
        #expect(response.series.count == (raw["series"] as? [Any])?.count)
        let item = try #require(response.libraryItems.first)
        #expect(item.id == "item-fixture")
        #expect(item.book?.metadata.title == "Author Tale")
        #expect(item.book?.metadata.authorName == "Author Fixture")
        #expect(item.book?.metadata.seriesName == "Fixture Cycle #2.5")
        #expect(item.book?.duration == (version == "2.26.0" ? 30.096 : 30))
        let group = try #require(response.series.first)
        #expect(group.id == "series-fixture")
        #expect(group.name == "Fixture Cycle")
        #expect(group.items.map(\.id) == [item.id])
        let association = try #require(group.items.first)
        #expect(association.libraryId == item.libraryId)
        #expect(association.series?.id == group.id)
        #expect(association.series?.name == group.name)
        #expect(association.series?.nameIgnorePrefix == "Fixture Cycle")
        #expect(association.series?.sequence == "2.5")
    }

    @Test func flatMetadataAndUnknownFields() throws {
        let response = try decode(
            #"""
            {"id":"a","name":"Author","asin":"synthetic-asin","description":"Biography",
             "imagePath":"/synthetic/author.jpg","libraryId":"lib","addedAt":123,"updatedAt":456,
             "numBooks":2,"future":{"value":true},"libraryItems":[
               {"id":"future","libraryId":"lib","mediaType":"future-kind","media":{"future":true}}
             ]}
            """#)
        #expect(response.author.asin == "synthetic-asin")
        #expect(response.author.description == "Biography")
        #expect(response.author.imagePath == "/synthetic/author.jpg")
        #expect(response.author.numBooks == 2)
        #expect(response.author.addedAt == 123)
        #expect(response.author.updatedAt == 456)
        #expect(response.libraryItems.map(\.id) == ["future"])
        #expect(response.libraryItems.first?.mediaType.rawValue == "future-kind")
        #expect(response.libraryItems.first?.media == nil)
    }

    @Test(arguments: [
        #"{"id":"a","name":"Author"}"#,
        #"{"id":"a","name":"Author","asin":null,"description":null,"imagePath":null,"libraryId":null,"addedAt":null,"updatedAt":null,"numBooks":null,"libraryItems":null,"series":null}"#,
    ])
    func absentAndNullOptionalValues(json: String) throws {
        let response = try decode(json)
        #expect(response.author == Author(id: "a", name: "Author"))
        #expect(response.libraryItems.isEmpty)
        #expect(response.series.isEmpty)
    }

    @Test func malformedMembersDoNotDiscardNeighborsOrSequenceOrder() throws {
        let response = try decode(
            #"""
            {"id":"a","name":"Author","libraryItems":[null,17,{"id":"broken"},
              {"id":"one","libraryId":"lib","mediaType":"book","media":{"id":"b","metadata":{"title":"One"}}},
              {"id":"two","libraryId":"lib","mediaType":"book"}],
             "series":[null,{"id":"broken"},{"id":"s","name":"Cycle","items":[
               false,{"libraryId":"lib"},
               {"id":"two","libraryId":"lib","media":{"metadata":{"series":{"id":"s","name":"Cycle","sequence":"2"}}}},
               {"id":"bad","libraryId":"lib","media":{"metadata":{"series":17}}},
               {"id":"one","libraryId":"lib","media":{"metadata":{"series":{"id":"s","name":"Cycle","sequence":"10"}}}}
             ]},{"id":"empty","name":"Empty","items":null}]}
            """#)
        #expect(response.libraryItems.map(\.id) == ["one", "two"])
        #expect(response.series.map(\.id) == ["s", "empty"])
        #expect(response.series.first?.items.map(\.id) == ["two", "one"])
        #expect(response.series.first?.items.map(\.series?.sequence) == ["2", "10"])
        #expect(response.series.last?.items.isEmpty == true)
    }

    @Test(arguments: [
        #"{}"#, #"{"media":null}"#, #"{"media":{}}"#, #"{"media":{"metadata":null}}"#,
        #"{"media":{"metadata":{}}}"#, #"{"media":{"metadata":{"series":null}}}"#,
    ])
    func optionalAssociationMetadataDoesNotDropTheReference(fragment: String) throws {
        var object = try #require(JSONSerialization.jsonObject(with: Data(fragment.utf8)) as? [String: Any])
        object["id"] = "item"
        object["libraryId"] = "lib"
        let data = try JSONSerialization.data(withJSONObject: object)
        let association = try JSONDecoder().decode(AuthorSeriesItem.self, from: data)
        #expect(association.id == "item")
        #expect(association.series == nil)
    }

    @Test func authorIdentityIsRequired() {
        for json in ["{}", #"{"id":"a"}"#, #"{"name":"Author"}"#] {
            #expect(throws: DecodingError.self) { try decode(json) }
        }
    }
}
