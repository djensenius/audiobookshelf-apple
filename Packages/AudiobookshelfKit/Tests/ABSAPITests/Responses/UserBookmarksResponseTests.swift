import ABSCore
import Foundation
import Testing

@testable import ABSAPI

@Suite struct UserBookmarksResponseTests {
    private func decode(_ json: String) throws -> UserBookmarksResponse {
        try JSONDecoder().decode(UserBookmarksResponse.self, from: Data(json.utf8))
    }

    @Test func decodesNumericStringTime() throws {
        let response = try decode(
            #"{"id":"u1","mediaProgress":[{"libraryItemId":"x"}],"bookmarks":["#
                + #"{"libraryItemId":"li","title":"Number","time":12,"createdAt":1700},"#
                + #"{"libraryItemId":"li","title":"String","time":"42.5"}]}"#)

        #expect(
            response.bookmarks == [
                AudioBookmark(libraryItemId: "li", title: "Number", time: 12, createdAt: 1_700),
                AudioBookmark(libraryItemId: "li", title: "String", time: 42.5),
            ])
    }

    @Test func skipsMalformedEntries() throws {
        let response = try decode(
            #"{"bookmarks":[{"title":"No item","time":1},{"libraryItemId":"li","time":"soon"},"#
                + #"{"libraryItemId":"li","title":"Kept","time":3},"oops"]}"#)

        #expect(response.bookmarks == [AudioBookmark(libraryItemId: "li", title: "Kept", time: 3)])
    }

    @Test func missingKeyIsEmpty() throws {
        #expect(try decode(#"{"id":"u1"}"#).bookmarks.isEmpty)
        #expect(try decode(#"{"bookmarks":null}"#).bookmarks.isEmpty)
    }

    @Test func malformedListThrows() {
        #expect(throws: DecodingError.self) { try decode(#"{"bookmarks":"oops"}"#) }
    }

    @Test func meBookmarksGetsTheCurrentUser() async throws {
        let stub = StubServer { _ in .json(#"{"id":"u1","bookmarks":[{"libraryItemId":"li","time":7}]}"#) }
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: stub.baseURL),
            tokenProvider: InMemoryTokenProvider(), sessionConfiguration: stub.sessionConfiguration())

        let response = try await client.send(UserEndpoints.meBookmarks())

        #expect(response.bookmarks == [AudioBookmark(libraryItemId: "li", time: 7)])
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path() == "/abs/api/me")
    }
}
