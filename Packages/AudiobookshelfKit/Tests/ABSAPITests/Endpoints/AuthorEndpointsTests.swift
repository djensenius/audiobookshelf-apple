import Foundation
import Testing

@testable import ABSAPI

@Suite struct AuthorEndpointsTests {
    @Test(arguments: [
        ("author-1", "author-1"), ("a/b?c#d%e f", "a%2Fb%3Fc%23d%25e%20f"),
        (".", "%2E"), ("..", "%2E%2E"),
    ])
    func authenticatedGETEncodesIDAndPreservesProxyBase(id: String, encoded: String) throws {
        let endpoint = AuthorEndpoints.author(id: id)
        #expect(endpoint.method == .get)
        #expect(endpoint.requiresAuthentication)
        let base = try #require(URL(string: "https://abs.example/proxy/abs"))
        let url = try APIClient.url(base: base, path: endpoint.path, query: endpoint.query)
        #expect(url.absoluteString == "https://abs.example/proxy/abs/api/authors/\(encoded)?include=items,series")
    }

    @Test func clientSendsBearerAndDecodesRealResponse() async throws {
        let data = try authorDetailFixture("2.37.2")
        let stub = StubServer { _ in
            StubResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
        }
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: stub.baseURL),
            tokenProvider: InMemoryTokenProvider(), sessionConfiguration: stub.sessionConfiguration())
        let response = try await client.send(AuthorEndpoints.author(id: "author-fixture"))
        #expect(response.author.id == "author-fixture")
        #expect(response.libraryItems.map(\.id) == ["item-fixture"])
        #expect(response.series.first?.items.first?.series?.sequence == "2.5")
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.url?.path() == "/abs/api/authors/author-fixture")
        #expect(request.url?.query() == "include=items,series")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
    }

    @Test func missingAuthorUsesClientNotFoundError() async throws {
        let stub = StubServer { _ in .text("Not Found", status: 404) }
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: stub.baseURL),
            tokenProvider: InMemoryTokenProvider(), sessionConfiguration: stub.sessionConfiguration())
        let error = await #expect(throws: APIError.self) {
            try await client.send(AuthorEndpoints.author(id: "missing"))
        }
        guard case .notFound? = error else {
            Issue.record("Expected notFound, got \(String(describing: error))")
            return
        }
    }
}
