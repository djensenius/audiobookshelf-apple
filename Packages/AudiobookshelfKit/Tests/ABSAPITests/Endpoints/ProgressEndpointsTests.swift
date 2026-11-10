import ABSCore
import Foundation
import Testing

@testable import ABSAPI

private func url<Response>(_ endpoint: Endpoint<Response>) throws -> String {
    let base = try #require(URL(string: "https://abs.example/abs"))
    return try APIClient.url(base: base, path: endpoint.path, query: endpoint.query).absoluteString
}

private func json(_ update: MediaProgressUpdate) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as? [String: Any])
}

private func json(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
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
            try url(ProgressEndpoints.update(itemID: "li1", episodeID: "", .finished(true)))
                == "\(server)/api/me/progress/li1")
    }

    @Test func patchProgressAndEpisode() throws {
        let book = ProgressEndpoints.update(itemID: "li1", .finished(true))
        #expect(book.method == .patch)
        #expect(try url(book) == "\(server)/api/me/progress/li1")
        let episode = ProgressEndpoints.update(itemID: "li1", episodeID: "ep1", .finished(true))
        #expect(episode.method == .patch)
        #expect(try url(episode) == "\(server)/api/me/progress/li1/ep1")
    }

    @Test func audioSendsOnlyAudioGroup() throws {
        let body = try json(.audio(currentTime: 12.5, duration: 100, progress: 0.125))
        #expect(Set(body.keys) == ["currentTime", "duration", "progress"])
        #expect(body["currentTime"] as? Double == 12.5)
        #expect(body["duration"] as? Double == 100)
        #expect(body["progress"] as? Double == 0.125)
    }

    @Test func finishedWithoutDateSendsOnlyIsFinished() throws {
        let finished = try json(.finished(true))
        #expect(Set(finished.keys) == ["isFinished"])
        #expect(finished["isFinished"] as? Bool == true)
        let unfinished = try json(.finished(false))
        #expect(Set(unfinished.keys) == ["isFinished"])
        #expect(unfinished["isFinished"] as? Bool == false)
    }

    @Test func finishedAtIsEpochMilliseconds() throws {
        let body = try json(.finished(true, at: Date(timeIntervalSince1970: 1_700_000_000.123)))
        #expect(Set(body.keys) == ["isFinished", "finishedAt"])
        #expect(body["finishedAt"] as? Int == 1_700_000_000_123)
    }

    @Test func finishedAtIsDroppedWhenNotFinished() throws {
        let body = try json(.finished(false, at: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(Set(body.keys) == ["isFinished"])
    }

    @Test func ebookSendsOnlyEbookGroup() throws {
        let body = try json(.ebook(location: "epubcfi(/6/4!/4/2)", progress: 0.25))
        #expect(Set(body.keys) == ["ebookLocation", "ebookProgress"])
        #expect(body["ebookLocation"] as? String == "epubcfi(/6/4!/4/2)")
        #expect(body["ebookProgress"] as? Double == 0.25)
    }

    @Test func hideFromContinueListeningSendsOneKey() throws {
        let body = try json(.hideFromContinueListening(true))
        #expect(Set(body.keys) == ["hideFromContinueListening"])
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
            ProgressEndpoints.update(itemID: "li1", .ebook(location: "5", progress: 0.5)))
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path() == "/abs/api/me/progress/li1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(Set(try json(request.httpBody).keys) == ["ebookLocation", "ebookProgress"])
    }

    @Test func clientSendsEpisodePatch() async throws {
        let stub = StubServer { _ in .text("OK", status: 200) }
        _ = try await makeClient(stub).send(
            ProgressEndpoints.update(
                itemID: "li1", episodeID: "ep1", .audio(currentTime: 30, duration: 600, progress: 0.05)))
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path() == "/abs/api/me/progress/li1/ep1")
        let body = try json(request.httpBody)
        #expect(Set(body.keys) == ["currentTime", "duration", "progress"])
        #expect(body["currentTime"] as? Double == 30)
    }

    @Test func clientDeletesProgress() async throws {
        let stub = StubServer { _ in .text("OK", status: 200) }
        _ = try await makeClient(stub).send(ProgressEndpoints.delete(id: "mp1"))
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path() == "/abs/api/me/progress/mp1")
        #expect(request.httpBody == nil)
    }
}
