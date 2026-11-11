import ABSCore
import Foundation
import Testing

@Suite struct CollectionModelTests {
    private func decode(_ json: String) throws -> LibraryCollection {
        try JSONDecoder().decode(LibraryCollection.self, from: Data(json.utf8))
    }

    @Test(arguments: [
        #"{"id":"c","libraryId":"l","name":"Collection"}"#,
        #"{"id":"c","libraryId":"l","name":"Collection","userId":null,"description":null,"cover":null,"coverFullPath":null,"books":null,"lastUpdate":null,"createdAt":null}"#,
    ])
    func absentAndNullRemainNil(json: String) throws {
        #expect(try decode(json) == LibraryCollection(id: "c", libraryId: "l", name: "Collection"))
    }

    @Test func malformedBooksKeepValidNeighborsInOrder() throws {
        let value = try decode(
            #"""
            {"id":"c","libraryId":"l","name":"Collection","future":true,"books":[
              {"id":"two","libraryId":"l","mediaType":"book","media":{"id":"b2","metadata":{"title":"Two"}}},
              null,17,{"id":"broken"},{"id":"bad","libraryId":"l","mediaType":"book","media":{"metadata":17}},
              {"id":"noMetadata","libraryId":"l","mediaType":"book","media":{"id":"b"}},
              {"id":"nullMetadata","libraryId":"l","mediaType":"book","media":{"id":"b","metadata":null}},
              {"id":"one","libraryId":"l","mediaType":"book","media":{"id":"b1","metadata":{"title":"One"}}}
            ]}
            """#)
        #expect(value.books?.map(\.id) == ["two", "one"])
        #expect(value.books?.first?.book?.metadata.title == "Two")
        #expect(value.books?.last?.book?.metadata.title == "One")
    }

    @Test func absentAndNullBookMediaDoNotDropIdentity() throws {
        let value = try decode(
            #"""
            {"id":"c","libraryId":"l","name":"Collection","books":[
              {"id":"one","libraryId":"l","mediaType":"book"},
              {"id":"two","libraryId":"l","mediaType":"book","media":null}
            ]}
            """#)
        #expect(value.books?.map(\.id) == ["one", "two"])
        #expect(value.books?.allSatisfy { $0.media == nil } == true)
    }

    @Test(arguments: [
        "{}", #"{"id":"c","name":"Collection"}"#, #"{"libraryId":"l","name":"Collection"}"#,
        #"{"id":"c","libraryId":"l"}"#, #"{"id":7,"libraryId":"l","name":"Collection"}"#,
        #"{"id":"c","libraryId":null,"name":"Collection"}"#, #"{"id":"c","libraryId":"l","name":false}"#,
        #"{"id":"c","libraryId":"l","name":"Collection","books":{}}"#,
    ])
    func malformedIdentityOrArrayStillThrows(json: String) {
        #expect(throws: DecodingError.self) { try decode(json) }
    }

    @Test func initializerAndCodablePreserveAllFieldsAndNilVersusEmpty() throws {
        for books: [LibraryItem]? in [
            nil, [], [LibraryItem(id: "i", libraryId: "l", mediaType: .book)],
        ] {
            let value = LibraryCollection(
                id: "c", libraryId: "l", userId: "u", name: "Collection", description: "",
                cover: "cover", coverFullPath: "/synthetic/cover", books: books, lastUpdate: 123, createdAt: 100)
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(LibraryCollection.self, from: data)
            #expect(decoded == value)
            let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect((raw["books"] as? [Any])?.count == books?.count)
        }
        #expect(try decode(#"{"id":"c","libraryId":"l","name":"Collection","books":[]}"#).books == [])
    }
}
