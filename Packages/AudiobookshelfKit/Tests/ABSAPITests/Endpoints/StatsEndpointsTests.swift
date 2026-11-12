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

    // MARK: Year in review

    @Test func yearStatsRequests() {
        let user = StatsEndpoints.userYearStats(year: 2024)
        #expect(user.method == .get)
        #expect(user.path == "/api/me/stats/year/2024")
        #expect(user.body == nil)
        #expect(user.requiresAuthentication)
        let server = StatsEndpoints.serverYearStats(year: 2023)
        #expect(server.method == .get)
        #expect(server.path == "/api/stats/year/2023")
        #expect(server.body == nil)
        #expect(server.requiresAuthentication)
        #expect(StatsEndpoints.userType().path == "/api/me")
    }

    /// The server's `userStats.getStatsForYear` response, trimmed.
    @Test func clientDecodesUserYearStats() async throws {
        let stub = StubServer { _ in
            .json(
                #"{"totalListeningSessions":42,"totalListeningTime":90000,"totalBookListeningTime":80000,"#
                    + #""totalPodcastListeningTime":10000,"topAuthors":[{"name":"Author One","time":50000}],"#
                    + #""topGenres":[{"genre":"Fantasy","time":60000}],"#
                    + #""mostListenedNarrator":{"time":40000,"name":"Narrator One"},"#
                    + #""mostListenedMonth":{"month":2,"time":20000},"numBooksFinished":3,"numBooksListened":5,"#
                    + #""longestAudiobookFinished":null,"booksWithCovers":["li-2"],"#
                    + #""finishedBooksWithCovers":["li-1"]}"#)
        }
        let stats = try await makeClient(stub).send(StatsEndpoints.userYearStats(year: 2024))
        #expect(stats.totalListeningSessions == 42)
        #expect(stats.totalListeningTime == 90000)
        #expect(stats.topAuthors == [YearStatsNameTime(name: "Author One", time: 50000)])
        #expect(stats.topGenres == [YearStatsGenreTime(genre: "Fantasy", time: 60000)])
        #expect(stats.mostListenedMonth == YearStatsMonthTime(month: 2, time: 20000))
        #expect(stats.numBooksFinished == 3)
        #expect(stats.longestAudiobookFinished == nil)
        #expect(stats.booksWithCovers == ["li-2"])
        #expect(stats.finishedBooksWithCovers == ["li-1"])
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path() == "/abs/api/me/stats/year/2024")
    }

    /// The server's `adminStats.getStatsForYear` response, trimmed.
    @Test func clientDecodesServerYearStats() async throws {
        let stub = StubServer { _ in
            .json(
                #"{"numListeningSessions":120,"numBooksAdded":10,"numAuthorsAdded":4,"#
                    + #""totalBooksAddedSize":5368709120,"totalBooksAddedDuration":360000,"#
                    + #""booksAddedWithCovers":["li-1"],"totalBooksSize":10737418240,"#
                    + #""totalBooksDuration":720000.75,"totalListeningTime":"250000.5","numBooks":20,"#
                    + #""topAuthors":[{"name":"Author One","time":100000}],"#
                    + #""topNarrators":[{"name":"Narrator One","time":90000}],"topGenres":[]}"#)
        }
        let stats = try await makeClient(stub).send(StatsEndpoints.serverYearStats(year: 2023))
        #expect(stats.numListeningSessions == 120)
        #expect(stats.numBooksAdded == 10)
        #expect(stats.totalBooksAddedSize == 5_368_709_120)
        #expect(stats.totalListeningTime == 250000.5)
        #expect(stats.booksAddedWithCovers == ["li-1"])
        #expect(stats.topNarrators == [YearStatsNameTime(name: "Narrator One", time: 90000)])
        let request = try #require(stub.requests.first)
        #expect(request.url?.path() == "/abs/api/stats/year/2023")
    }

    /// A non-admin asking for the server's year gets 403 from the server's stats middleware.
    @Test func serverYearStatsIsForbiddenForNonAdmins() async throws {
        let stub = StubServer { _ in .text("Forbidden", status: 403) }
        await #expect(throws: APIError.forbidden(message: "Forbidden")) {
            try await makeClient(stub).send(StatsEndpoints.serverYearStats(year: 2023))
        }
    }

    @Test func userTypeDecodesOnlyTheType() async throws {
        let stub = StubServer { _ in
            .json(#"{"id":"usr-1","username":"david","type":"admin","mediaProgress":[{"id":"mp-1"}]}"#)
        }
        let response = try await makeClient(stub).send(StatsEndpoints.userType())
        #expect(response.type == .admin)
        #expect(response.isAdminOrUp)
        let request = try #require(stub.requests.first)
        #expect(request.url?.path() == "/abs/api/me")
    }

    @Test func onlyAdminAndRootAreAdminOrUp() throws {
        func decode(_ json: String) throws -> UserTypeResponse {
            try JSONDecoder().decode(UserTypeResponse.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{"type":"root"}"#).isAdminOrUp)
        #expect(try decode(#"{"type":"admin"}"#).isAdminOrUp)
        #expect(try !decode(#"{"type":"user"}"#).isAdminOrUp)
        #expect(try !decode(#"{"type":"guest"}"#).isAdminOrUp)
        #expect(try !decode(#"{"type":"superuser"}"#).isAdminOrUp)
        #expect(try decode(#"{"type":7}"#).type == .user)
        #expect(try decode(#"{}"#).type == .user)
    }
}
