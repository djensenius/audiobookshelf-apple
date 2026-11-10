import Foundation
import Testing

@testable import ABSAPI

@Suite struct SeriesEndpointsTests {
    @Test(arguments: [
        ("series-1", "series-1"), ("a/b?c#d%e f", "a%2Fb%3Fc%23d%25e%20f"),
        (".", "%2E"), ("..", "%2E%2E"), ("séries", "s%C3%A9ries"),
    ])
    func authenticatedGETEncodesOneSegmentAndPreservesProxyBase(id: String, encoded: String) throws {
        let base = try #require(URL(string: "https://abs.example/proxy/abs"))
        for include in [true, false] {
            let endpoint = SeriesEndpoints.detail(id: id, includeProgress: include)
            #expect(endpoint.method == .get)
            #expect(endpoint.requiresAuthentication)
            let url = try APIClient.url(base: base, path: endpoint.path, query: endpoint.query)
            let suffix = include ? "?include=progress" : ""
            #expect(url.absoluteString == "https://abs.example/proxy/abs/api/series/\(encoded)\(suffix)")
        }
    }

    @Test func defaultsToProgressWithoutChangingMetadataEndpoint() {
        let detail = SeriesEndpoints.detail(id: "s")
        #expect(detail.query == [URLQueryItem(name: "include", value: "progress")])
        let metadata = ItemEndpoints.series(id: "s")
        #expect(metadata.path == detail.path)
        #expect(metadata.query.isEmpty)
    }

    @Test(arguments: ["2.26.0", "2.37.2"])
    func clientSendsBearerAndDecodesCapturedResponse(version: String) async throws {
        let data = try seriesDetailFixture(version)
        let stub = StubServer { _ in
            StubResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
        }
        let client = try client(for: stub)
        let response = try await client.send(SeriesEndpoints.detail(id: "series-fixture"))
        #expect(response.series.id == "series-fixture")
        #expect(response.progress?.libraryItemIds == ["item-one", "item-two"])
        #expect(response.progress?.libraryItemIdsFinished == ["item-one"])
        #expect(response.progress?.isFinished == false)
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.url?.path() == "/abs/api/series/series-fixture")
        #expect(request.url?.query() == "include=progress")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
    }

    @Test func omittedIncludeDecodesMetadataOnly() async throws {
        let stub = StubServer { _ in .json(#"{"id":"s","name":"Series"}"#) }
        let response = try await client(for: stub).send(SeriesEndpoints.detail(id: "s", includeProgress: false))
        #expect(response.series.id == "s")
        #expect(response.progress == nil)
        #expect(try #require(stub.requests.first).url?.query() == nil)
    }

    @Test func missingSeriesUsesClientNotFoundError() async throws {
        let stub = StubServer { _ in .text("Not Found", status: 404) }
        let client = try client(for: stub)
        await #expect(throws: APIError.notFound) {
            try await client.send(SeriesEndpoints.detail(id: "missing"))
        }
    }

    @Test func malformedAggregateIsADecodingErrorNotEmptyProgress() async throws {
        let stub = StubServer { _ in .json(#"{"id":"s","name":"Series","progress":{}}"#) }
        let client = try client(for: stub)
        let error = await #expect(throws: APIError.self) {
            try await client.send(SeriesEndpoints.detail(id: "s"))
        }
        guard case .decoding? = error else {
            Issue.record("Expected decoding error, got \(String(describing: error))")
            return
        }
    }

    private func client(for stub: StubServer) throws -> APIClient {
        APIClient(
            configuration: try APIClientConfiguration(baseURL: stub.baseURL),
            tokenProvider: InMemoryTokenProvider(), sessionConfiguration: stub.sessionConfiguration())
    }
}
