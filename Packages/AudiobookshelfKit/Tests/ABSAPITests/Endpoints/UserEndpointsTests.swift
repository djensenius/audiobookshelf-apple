import ABSCore
import Foundation
import Testing

@testable import ABSAPI

@Suite struct UserEndpointsTests {
    @Test func me() async throws {
        let endpoint = UserEndpoints.me
        #expect(endpoint.method == .get)
        #expect(endpoint.requiresAuthentication)
        #expect(endpoint.body == nil)
        let base = try #require(URL(string: "https://abs.example/abs"))
        let url = try APIClient.url(base: base, path: endpoint.path, query: endpoint.query)
        #expect(url.absoluteString == "https://abs.example/abs/api/me")

        let stub = StubServer { _ in .json(#"{"id": "u1", "username": "me", "mediaProgress": []}"#) }
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: stub.baseURL), tokenProvider: InMemoryTokenProvider(),
            sessionConfiguration: stub.sessionConfiguration())
        let user = try await client.send(endpoint)
        #expect(user.id == "u1")
        #expect(user.username == "me")
    }
}
