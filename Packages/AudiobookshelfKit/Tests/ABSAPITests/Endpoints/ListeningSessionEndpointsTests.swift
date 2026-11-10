import ABSCore
import Foundation
import Testing

@testable import ABSAPI

@Suite struct ListeningSessionEndpointsTests {
    private func makeClient(_ server: StubServer) throws -> APIClient {
        APIClient(
            configuration: try APIClientConfiguration(baseURL: server.baseURL),
            tokenProvider: InMemoryTokenProvider(),
            sessionConfiguration: server.sessionConfiguration()
        )
    }

    @Test func bookPathAndPagingQuery() async throws {
        let server = StubServer { _ in .json(#"{"total":0,"numPages":0,"page":0,"itemsPerPage":10,"sessions":[]}"#) }
        let page = try await makeClient(server).send(SessionEndpoints.listeningSessions(itemID: "li/1"))

        let sent = try #require(server.requests.first)
        #expect(sent.httpMethod == "GET")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        #expect(
            sent.url?.absoluteString
                == "https://\(server.host)/abs/api/me/item/listening-sessions/li%2F1?itemsPerPage=10&page=0")
        #expect(page.sessions.isEmpty)
        #expect(page.total == 0)
    }

    @Test func episodePathEncodesEverySegment() throws {
        let endpoint = SessionEndpoints.listeningSessions(itemID: "..", episodeID: "ep 1?x", page: 2, itemsPerPage: 5)
        #expect(endpoint.path == "/api/me/item/listening-sessions/%2E%2E/ep%201%3Fx")
        #expect(endpoint.query.map(\.value) == ["5", "2"])
        #expect(SessionEndpoints.listeningSessions(itemID: "li", episodeID: "").path.hasSuffix("/li"))
    }

    @Test func decodesNewestFirstWithLenientFields() async throws {
        let json = #"""
            {"total": 3, "numPages": 1, "page": 0, "itemsPerPage": 10, "sessions": [
              {"id": "s-new", "libraryItemId": "li-1", "timeListening": 42.5, "currentTime": 1300, "updatedAt": 1762732842500},
              {"id": "s-mid", "timeListening": "7", "currentTime": 600, "updatedAt": "soon"},
              {"id": "s-old", "timeListening": null, "currentTime": 12, "updatedAt": 1762732800000.0}
            ]}
            """#
        let server = StubServer { _ in .json(json) }
        let page = try await makeClient(server).send(SessionEndpoints.listeningSessions(itemID: "li-1"))
        #expect(
            page.sessions == [
                ListeningSessionRecord(
                    id: "s-new", timeListening: 42.5, currentTime: 1300, updatedAt: 1_762_732_842_500),
                ListeningSessionRecord(id: "s-mid", timeListening: 7, currentTime: 600),
                ListeningSessionRecord(id: "s-old", timeListening: 0, currentTime: 12, updatedAt: 1_762_732_800_000),
            ])
        #expect(page.total == 3)
        #expect(page.numPages == 1)
    }

    /// A page missing a session would read as "never stored" during reconciliation, so a session
    /// that can't be decoded fails the page instead.
    @Test(arguments: [
        #"{"timeListening": 1, "currentTime": 2}"#,
        #"{"id": "s", "timeListening": "lots", "currentTime": 2}"#,
        #"{"id": "s", "timeListening": 1, "currentTime": {"a": 1}}"#,
    ])
    func undecodableSessionFailsThePage(session: String) async throws {
        let json =
            #"{"total": 2, "numPages": 1, "page": 0, "itemsPerPage": 10, "sessions": ["#
            + #"{"id": "ok", "timeListening": 5, "currentTime": 5}, "# + session + "]}"
        let server = StubServer { _ in .json(json) }
        await #expect {
            try await makeClient(server).send(SessionEndpoints.listeningSessions(itemID: "li-1"))
        } throws: { error in
            if case .decoding = error as? APIError { true } else { false }
        }
    }

    @Test func missingItemIsNotFound() async throws {
        let server = StubServer { _ in .text("Not Found", status: 404) }
        await #expect(throws: APIError.notFound) {
            try await makeClient(server).send(SessionEndpoints.listeningSessions(itemID: "gone"))
        }
    }

    @Test(arguments: ["{}", #"{"sessions":null}"#, #"{"sessions":{}}"#])
    func missingOrInvalidSessionsFailsClosed(json: String) async throws {
        let server = StubServer { _ in .json(json) }
        await #expect {
            try await makeClient(server).send(SessionEndpoints.listeningSessions(itemID: "li-1"))
        } throws: { error in
            if case .decoding = error as? APIError { true } else { false }
        }
    }
}
