import ABSCore
import Foundation
import Testing

@testable import ABSAPI

@Suite struct StatsEndpointsTests {
    private func makeClient(_ stub: StubServer) throws -> APIClient {
        APIClient(
            configuration: try APIClientConfiguration(baseURL: stub.baseURL),
            tokenProvider: InMemoryTokenProvider(),
            sessionConfiguration: stub.sessionConfiguration()
        )
    }

    @Test func listeningStatsRequest() throws {
        let endpoint = StatsEndpoints.listeningStats()
        #expect(endpoint.method == .get)
        #expect(endpoint.path == "/api/me/listening-stats")
        #expect(endpoint.body == nil)
        #expect(endpoint.requiresAuthentication)
    }

    @Test func clientDecodesListeningStats() async throws {
        let stub = StubServer { _ in
            .json(
                #"{"totalTime":"90","items":{},"days":{"2024-03-01":90},"dayOfWeek":{},"today":0,"#
                    + #""recentSessions":[{"id":"ps-1","libraryItemId":"li-1","mediaType":"book","timeListening":90},"#
                    + #"{"id":"ps-2","libraryItemId":null,"mediaType":"book","timeListening":1}]}"#)
        }
        let stats = try await makeClient(stub).send(StatsEndpoints.listeningStats())
        #expect(stats.totalTime == 90)
        #expect(stats.days == ["2024-03-01": 90])
        #expect(stats.recentSessions.map(\.id) == ["ps-1"])
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path() == "/abs/api/me/listening-stats")
    }

    @Test func currentUserRequest() async throws {
        let stub = StubServer { _ in
            .json(
                #"{"id":"usr-1","username":"david","type":"user","mediaProgress":["#
                    + #"{"id":"mp-1","libraryItemId":"li-1","isFinished":true},"#
                    + #"{"id":"mp-2","libraryItemId":"li-2","isFinished":false}]}"#)
        }
        let user = try await makeClient(stub).send(StatsEndpoints.currentUser())
        #expect(user.mediaProgress.map(\.isFinished) == [true, false])
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path() == "/abs/api/me")
    }
}
