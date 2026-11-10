import ABSCore
import Foundation
import Testing

@testable import ABSAPI

private func url<Response>(_ endpoint: Endpoint<Response>) throws -> String {
    let base = try #require(URL(string: "https://abs.example/abs"))
    return try APIClient.url(base: base, path: endpoint.path, query: endpoint.query).absoluteString
}

private func json<Response>(_ endpoint: Endpoint<Response>) throws -> [String: Any] {
    let body = try #require(endpoint.body)
    return try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
}

private func makeClient(_ stub: StubServer) throws -> APIClient {
    APIClient(
        configuration: try APIClientConfiguration(baseURL: stub.baseURL),
        tokenProvider: InMemoryTokenProvider(),
        sessionConfiguration: stub.sessionConfiguration()
    )
}

private let server = "https://abs.example/abs"

@Suite struct BookmarkEndpointsTests {
    @Test func createBookmark() throws {
        let endpoint = BookmarkEndpoints.create(itemID: "li1", time: 125, title: "Chapter 3")
        #expect(endpoint.method == .post)
        #expect(try url(endpoint) == "\(server)/api/me/item/li1/bookmark")
        let body = try json(endpoint)
        #expect(Set(body.keys) == ["time", "title"])
        #expect(body["time"] as? Double == 125)
        #expect(body["title"] as? String == "Chapter 3")
    }

    @Test func updateBookmark() throws {
        let endpoint = BookmarkEndpoints.update(itemID: "li1", time: 12.75, title: "Renamed")
        #expect(endpoint.method == .patch)
        #expect(try url(endpoint) == "\(server)/api/me/item/li1/bookmark")
        let body = try json(endpoint)
        #expect(body["time"] as? Double == 12.75)
        #expect(body["title"] as? String == "Renamed")
    }

    @Test(arguments: [
        (125.0, "125"), (0.0, "0"), (-0.0, "0"), (12.5, "12.5"), (0.1, "0.1"), (3723.456, "3723.456"),
        (1e-5, "1e-05"),
    ])
    func deleteFormatsTime(time: Double, path: String) throws {
        let endpoint = BookmarkEndpoints.delete(itemID: "li1", time: time)
        #expect(endpoint.method == .delete)
        #expect(endpoint.body == nil)
        #expect(try url(endpoint) == "\(server)/api/me/item/li1/bookmark/\(path)")
    }

    @Test(arguments: [125.0, 12.5, 0.1, 3723.456, 1e-5, 1e20, 0.30000000000000004])
    func pathTimeRoundTrips(time: Double) {
        #expect(Double(BookmarkEndpoints.pathTime(time)) == time)
    }

    @Test func pathTimeIgnoresLocale() {
        // `String(describing:)` never uses a decimal comma; this guards against a switch to a
        // locale-aware formatter.
        #expect(!BookmarkEndpoints.pathTime(1234.5).contains(","))
        #expect(BookmarkEndpoints.pathTime(1234.5) == "1234.5")
    }

    @Test func itemIDIsEncodedAsOnePathSegment() throws {
        #expect(
            try url(BookmarkEndpoints.delete(itemID: "a/b", time: 1)) == "\(server)/api/me/item/a%2Fb/bookmark/1")
        #expect(
            try url(BookmarkEndpoints.create(itemID: "a/b", time: 1, title: "x"))
                == "\(server)/api/me/item/a%2Fb/bookmark")
    }

    @Test func clientDecodesCreatedBookmark() async throws {
        let stub = StubServer { _ in
            .json(#"{"libraryItemId":"li1","time":12.5,"title":"Here","createdAt":1700000000000}"#)
        }
        let bookmark = try await makeClient(stub).send(
            BookmarkEndpoints.create(itemID: "li1", time: 12.5, title: "Here"))
        #expect(
            bookmark == AudioBookmark(libraryItemId: "li1", title: "Here", time: 12.5, createdAt: 1_700_000_000_000))
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/abs/api/me/item/li1/bookmark")
    }

    @Test func clientUpdateOfMissingBookmarkThrowsNotFound() async throws {
        let stub = StubServer { _ in .text("Not Found", status: 404) }
        await #expect(throws: APIError.notFound) {
            try await makeClient(stub).send(BookmarkEndpoints.update(itemID: "li1", time: 12.5, title: "Gone"))
        }
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "PATCH")
    }

    @Test func clientDeletesFractionalTime() async throws {
        let stub = StubServer { _ in .text("OK", status: 200) }
        _ = try await makeClient(stub).send(BookmarkEndpoints.delete(itemID: "li1", time: 12.5))
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path() == "/abs/api/me/item/li1/bookmark/12.5")
    }
}
