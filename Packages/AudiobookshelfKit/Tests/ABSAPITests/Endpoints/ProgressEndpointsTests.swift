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

@Suite struct ProgressEndpointsTests {
    @Test func getProgress() throws {
        let endpoint = ProgressEndpoints.progress(itemID: "li1")
        #expect(endpoint.method == .get)
        #expect(endpoint.requiresAuthentication)
        #expect(endpoint.body == nil)
        #expect(try url(endpoint) == "\(server)/api/me/progress/li1")
    }

    @Test func getEpisodeProgress() throws {
        #expect(
            try url(ProgressEndpoints.progress(itemID: "li1", episodeID: "ep1")) == "\(server)/api/me/progress/li1/ep1")
    }

    @Test func emptyEpisodeIDCountsAsNone() throws {
        #expect(try url(ProgressEndpoints.progress(itemID: "li1", episodeID: "")) == "\(server)/api/me/progress/li1")
        #expect(
            try url(ProgressEndpoints.update(itemID: "li1", episodeID: "", MediaProgressUpdate(isFinished: true)))
                == "\(server)/api/me/progress/li1")
    }

    @Test func patchProgressAndEpisode() throws {
        let book = ProgressEndpoints.update(itemID: "li1", MediaProgressUpdate(isFinished: true))
        #expect(book.method == .patch)
        #expect(try url(book) == "\(server)/api/me/progress/li1")
        let episode = ProgressEndpoints.update(itemID: "li1", episodeID: "ep1", MediaProgressUpdate(isFinished: true))
        #expect(episode.method == .patch)
        #expect(try url(episode) == "\(server)/api/me/progress/li1/ep1")
    }

    @Test func patchSendsOnlySetFields() throws {
        let finished = try json(ProgressEndpoints.update(itemID: "li1", MediaProgressUpdate(isFinished: false)))
        #expect(Set(finished.keys) == ["isFinished"])
        #expect(finished["isFinished"] as? Bool == false)

        let ebook = try json(
            ProgressEndpoints.update(
                itemID: "li1", MediaProgressUpdate(ebookLocation: "epubcfi(/6/4!/4/2)", ebookProgress: 0.25)))
        #expect(Set(ebook.keys) == ["ebookLocation", "ebookProgress"])
        #expect(ebook["ebookLocation"] as? String == "epubcfi(/6/4!/4/2)")
        #expect(ebook["ebookProgress"] as? Double == 0.25)

        let audio = try json(
            ProgressEndpoints.update(
                itemID: "li1", MediaProgressUpdate(currentTime: 12.5, duration: 100, progress: 0.125)))
        #expect(Set(audio.keys) == ["currentTime", "duration", "progress"])
        #expect(audio["currentTime"] as? Double == 12.5)
        #expect(audio["duration"] as? Double == 100)
        #expect(audio["progress"] as? Double == 0.125)
    }

    @Test func patchSendsEveryField() throws {
        let update = MediaProgressUpdate(
            currentTime: 1, duration: 2, progress: 0.5, isFinished: true, ebookLocation: "3", ebookProgress: 0.75,
            hideFromContinueListening: true)
        let body = try json(ProgressEndpoints.update(itemID: "li1", update))
        #expect(
            Set(body.keys) == [
                "currentTime", "duration", "progress", "isFinished", "ebookLocation", "ebookProgress",
                "hideFromContinueListening",
            ])
        #expect(body["hideFromContinueListening"] as? Bool == true)
    }

    @Test func deleteProgressByProgressID() throws {
        let endpoint = ProgressEndpoints.delete(id: "mp1")
        #expect(endpoint.method == .delete)
        #expect(endpoint.body == nil)
        #expect(try url(endpoint) == "\(server)/api/me/progress/mp1")
    }

    @Test func idsAreEncodedAsOnePathSegment() throws {
        #expect(
            try url(ProgressEndpoints.progress(itemID: "a/b", episodeID: "c?d"))
                == "\(server)/api/me/progress/a%2Fb/c%3Fd")
        #expect(try url(ProgressEndpoints.delete(id: "..")) == "\(server)/api/me/progress/%2E%2E")
    }

    @Test func clientReturnsProgress() async throws {
        let stub = StubServer { _ in
            .json(#"{"id":"mp1","libraryItemId":"li1","episodeId":"ep1","currentTime":42,"duration":100}"#)
        }
        let progress = try await makeClient(stub).mediaProgress(itemID: "li1", episodeID: "ep1")
        #expect(progress?.id == "mp1")
        #expect(progress?.currentTime == 42)
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path() == "/abs/api/me/progress/li1/ep1")
    }

    @Test func clientMapsNotFoundToNil() async throws {
        let stub = StubServer { _ in .text("Not Found", status: 404) }
        let progress = try await makeClient(stub).mediaProgress(itemID: "li1")
        #expect(progress == nil)
    }

    @Test func clientThrowsOtherErrors() async throws {
        let stub = StubServer { _ in .text("Forbidden", status: 403) }
        await #expect(throws: APIError.forbidden(message: "Forbidden")) {
            try await makeClient(stub).mediaProgress(itemID: "li1")
        }
    }

    @Test func clientSendsPatchBody() async throws {
        let stub = StubServer { _ in .text("OK", status: 200) }
        _ = try await makeClient(stub).send(
            ProgressEndpoints.update(itemID: "li1", MediaProgressUpdate(ebookLocation: "5", ebookProgress: 0.5)))
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path() == "/abs/api/me/progress/li1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(object.keys) == ["ebookLocation", "ebookProgress"])
    }
}

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

    @Test func clientDeletesFractionalTime() async throws {
        let stub = StubServer { _ in .text("OK", status: 200) }
        _ = try await makeClient(stub).send(BookmarkEndpoints.delete(itemID: "li1", time: 12.5))
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path() == "/abs/api/me/item/li1/bookmark/12.5")
    }
}
