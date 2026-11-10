import Foundation
import Testing

@testable import ABSAPI

private func makeClient(_ server: StubServer, baseURL: URL? = nil) throws -> APIClient {
    APIClient(
        configuration: try APIClientConfiguration(
            baseURL: baseURL ?? server.baseURL, customHeaders: ["CF-Access-Client-Secret": "proxy-secret"]),
        tokenProvider: InMemoryTokenProvider(),
        sessionConfiguration: server.sessionConfiguration()
    )
}

private func hasCredentials(_ request: URLRequest?) -> Bool {
    request?.value(forHTTPHeaderField: "Authorization") != nil
        || request?.value(forHTTPHeaderField: "CF-Access-Client-Secret") != nil
        || request?.value(forHTTPHeaderField: "Cookie") != nil
        || request?.value(forHTTPHeaderField: "x-return-tokens") != nil
}

@Suite struct APIClientRedirectTests {
    @Test func sameOriginRedirectKeepsTokenAndCustomHeaders() async throws {
        let server = StubServer { request in
            request.url?.path() == "/abs/a" ? .redirect(to: "https://\(request.url?.host() ?? "")/abs/b") : .json("{}")
        }
        let client = try makeClient(server)

        _ = try await client.send(Endpoint<EmptyResponse>(.get, "/a", headers: ["x-return-tokens": "true"]))

        let followed = try #require(server.requests(path: "/abs/b").first)
        #expect(followed.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        #expect(followed.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "proxy-secret")
        #expect(followed.value(forHTTPHeaderField: "x-return-tokens") == "true")
    }

    @Test func upgradeToHTTPSOnSameHostKeepsCredentials() async throws {
        let server = StubServer { request in
            request.url?.scheme == "http"
                ? .redirect(to: "https://\(request.url?.host() ?? "")/abs/a", status: 301) : .json("{}")
        }
        let client = try makeClient(server, baseURL: URL(string: "http://\(server.host)/abs"))

        _ = try await client.send(Endpoint<EmptyResponse>(.get, "/a"))

        let followed = try #require(server.requests.last)
        #expect(followed.url?.scheme == "https")
        #expect(followed.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        #expect(followed.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "proxy-secret")
    }

    @Test func crossOriginRedirectStripsCredentials() async throws {
        let other = StubServer { _ in .json("{}") }
        let server = StubServer { _ in .redirect(to: "https://\(other.host)/files/cover.jpg") }
        let client = try makeClient(server)

        _ = try await client.send(Endpoint<EmptyResponse>(.get, "/a", headers: ["x-return-tokens": "true"]))

        let followed = try #require(other.requests.first)
        #expect(followed.url?.path() == "/files/cover.jpg")
        #expect(!hasCredentials(followed))
    }

    @Test func differentPortIsCrossOrigin() async throws {
        let server = StubServer { request in
            request.url?.port == nil ? .redirect(to: "https://\(request.url?.host() ?? ""):8443/b") : .json("{}")
        }
        let client = try makeClient(server)

        _ = try await client.send(Endpoint<EmptyResponse>(.get, "/a"))

        #expect(server.requests.count == 2)
        #expect(!hasCredentials(server.requests.last))
    }

    @Test func redirectBackToOriginStaysUncredentialed() async throws {
        let originHost = StubServer.uniqueHost()
        let otherHost = StubServer.uniqueHost()
        let origin = StubServer(host: originHost) { request in
            request.url?.path() == "/abs/a" ? .redirect(to: "https://\(otherHost)/x") : .json("{}")
        }
        let other = StubServer(host: otherHost) { _ in .redirect(to: "https://\(originHost)/abs/c") }
        let client = try makeClient(origin)

        _ = try await client.send(Endpoint<EmptyResponse>(.get, "/a"))

        #expect(other.requests.count == 1)
        let back = try #require(origin.requests(path: "/abs/c").first)
        #expect(!hasCredentials(other.requests.first))
        #expect(!hasCredentials(back))
    }

    @Test func downgradeToHTTPIsRefused() async throws {
        let server = StubServer { request in
            request.url?.scheme == "https" ? .redirect(to: "http://\(request.url?.host() ?? "")/abs/b") : .json("{}")
        }
        let client = try makeClient(server)

        await #expect(throws: APIError.redirectRefused(status: 302)) {
            try await client.send(Endpoint<EmptyResponse>(.get, "/a"))
        }
        #expect(server.requests.count == 1)
    }

    @Test func redirectDelegateDeclinesRedirects() async throws {
        let delegate = RedirectSuppressingDelegate()
        let url = try #require(URL(string: "https://example.com/a"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil))
        let task = URLSession.shared.dataTask(with: url)

        let next = await delegate.urlSession(
            .shared, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: url))

        #expect(next == nil)
    }

    @Test(arguments: [
        ("https://a.example", "https://a.example:443/x", true),
        ("https://a.example", "https://A.EXAMPLE/x", true),
        ("http://a.example", "https://a.example/x", true),
        ("http://a.example:8080", "https://a.example:8443/x", false),
        ("https://a.example", "http://a.example/x", false),
        ("https://a.example", "https://b.example/x", false),
        ("https://a.example", "https://a.example:8443/x", false),
    ])
    func comparesOrigins(current: String, next: String, expected: Bool) throws {
        let current = try #require(URL(string: current))
        let next = try #require(URL(string: next))
        #expect(RedirectPolicy.isSameOrigin(current, next) == expected)
    }
}
