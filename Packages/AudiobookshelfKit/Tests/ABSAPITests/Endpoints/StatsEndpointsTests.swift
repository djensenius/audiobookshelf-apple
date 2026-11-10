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
        let response = try await makeClient(stub).send(StatsEndpoints.listeningStats())
        #expect(response.stats.totalTime == 90)
        #expect(response.stats.days == ["2024-03-01": 90])
        #expect(response.stats.recentSessions.map(\.id) == ["ps-1"])
        #expect(response.recentSessions.map(\.id) == ["ps-1", "ps-2"])
        #expect(response.recentSessions.map(\.libraryItemId) == ["li-1", nil])
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path() == "/abs/api/me/listening-stats")
    }

    /// Old rows: a null or missing item ID, string numbers, malformed metadata. Only a session
    /// without an `id` is skipped.
    @Test func recentSessionSummariesDecodeLeniently() throws {
        let json =
            #"{"recentSessions":[{"id":"a","libraryItemId":null,"timeListening":"12.5","#
            + #""updatedAt":"1709283600000","mediaMetadata":"oops","displayTitle":"Shown"},"#
            + #"{"id":"b","libraryItemId":"","mediaMetadata":{"title":"Meta"},"displayTitle":"Display"},"#
            + #"{"id":"c","timeListening":null},{"libraryItemId":"li-x"}]}"#
        let response = try JSONDecoder().decode(ListeningStatsResponse.self, from: Data(json.utf8))
        #expect(
            response.recentSessions == [
                ListeningSessionSummary(id: "a", title: "Shown", timeListening: 12.5, updatedAt: 1_709_283_600_000),
                ListeningSessionSummary(id: "b", title: "Meta"),
                ListeningSessionSummary(id: "c"),
            ])
        #expect(response.stats.recentSessions.isEmpty)
    }

    @Test func finishedProgressRequest() async throws {
        let stub = StubServer { _ in
            .json(
                #"{"id":"usr-1","username":"david","type":"user","mediaProgress":["#
                    + #"{"id":"mp-1","libraryItemId":"li-1","isFinished":true},"#
                    + #"{"id":"mp-2","libraryItemId":"li-2","isFinished":false}]}"#)
        }
        let progress = try await makeClient(stub).send(StatsEndpoints.finishedProgress())
        #expect(progress.finished == [true, false])
        #expect(progress.finishedCount == 1)
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path() == "/abs/api/me")
    }

    /// Legacy counted every finished row, including old ones whose item ID is null, which
    /// `User.mediaProgress` drops. Only a row without a usable `isFinished` is skipped.
    @Test func finishedRowWithNullItemIdIsCounted() throws {
        let json =
            #"{"id":"usr-1","username":"david","mediaProgress":["#
            + #"{"id":"mp-1","libraryItemId":"li-1","isFinished":true},"#
            + #"{"id":"mp-2","libraryItemId":null,"isFinished":true},"#
            + #"{"libraryItemId":"li-3","episodeId":"ep-1","isFinished":true},"#
            + #"{"id":"mp-4","libraryItemId":"li-4","isFinished":false},{"id":"mp-5"}]}"#
        let progress = try JSONDecoder().decode(FinishedProgressResponse.self, from: Data(json.utf8))
        #expect(progress.finished == [true, true, true, false])
        #expect(progress.finishedCount == 3)
        let user = try JSONDecoder().decode(User.self, from: Data(json.utf8))
        #expect(user.mediaProgress.count(where: \.isFinished) < progress.finishedCount)
    }

    @Test func missingProgressCountsNothing() throws {
        let progress = try JSONDecoder().decode(FinishedProgressResponse.self, from: Data(#"{"id":"usr-1"}"#.utf8))
        #expect(progress.finishedCount == 0)
    }
}
