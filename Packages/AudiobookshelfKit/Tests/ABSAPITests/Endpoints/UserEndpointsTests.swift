import ABSCore
import Foundation
import Testing

@testable import ABSAPI

@Suite struct UserEndpointsTests {
    @Test func meDecodesOnlyFinishedFlagsLeniently() async throws {
        let stub = StubServer { _ in
            .json(
                #"{"id":"u1","username":"me","bookmarks":[],"mediaProgress":["#
                    + #"{"libraryItemId":"P","episodeId":"e1","isFinished":true,"currentTime":12},"#
                    + #"{"libraryItemId":"B","episodeId":null,"isFinished":"yes"},"#
                    + #"{"libraryItemId":"C"},{"episodeId":"orphan","isFinished":true}]}"#)
        }
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: stub.baseURL),
            tokenProvider: InMemoryTokenProvider(), sessionConfiguration: stub.sessionConfiguration())

        let response = try await client.send(UserEndpoints.me())

        #expect(
            response.mediaProgress == [
                .init(libraryItemId: "P", episodeId: "e1", isFinished: true),
                .init(libraryItemId: "B", isFinished: false),
                .init(libraryItemId: "C", isFinished: false),
            ])
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path() == "/abs/api/me")
    }

    @Test func meWithoutProgressDecodesEmpty() throws {
        let response = try JSONDecoder().decode(UserFinishedMediaResponse.self, from: Data(#"{"id":"u1"}"#.utf8))
        #expect(response.mediaProgress.isEmpty)
    }

    /// L1: a list that isn't one throws, rather than reading as "nothing finished".
    @Test func meWithMalformedProgressListThrows() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(UserFinishedMediaResponse.self, from: Data(#"{"mediaProgress":"oops"}"#.utf8))
        }
    }

    @Test func progressDecodesFullRowsLeniently() async throws {
        let stub = StubServer { _ in
            .json(
                #"{"id":"u1","mediaProgress":["#
                    + #"{"id":"p1","libraryItemId":"A","currentTime":12,"duration":100,"progress":0.12},"#
                    + #"{"id":"broken"}]}"#)
        }
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: stub.baseURL),
            tokenProvider: InMemoryTokenProvider(), sessionConfiguration: stub.sessionConfiguration())

        let response = try await client.send(UserEndpoints.progress())

        #expect(response.mediaProgress.map(\.id) == ["p1"])
        #expect(response.mediaProgress.first?.currentTime == 12)
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path() == "/abs/api/me")
    }

    /// A seed replaces the cache, so a payload without the list must not read as "no progress".
    @Test func progressWithoutListThrows() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(UserProgressResponse.self, from: Data(#"{"id":"u1"}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(UserProgressResponse.self, from: Data(#"{"mediaProgress":"oops"}"#.utf8))
        }
    }
}
