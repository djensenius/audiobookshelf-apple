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
            switch request.url?.path() {
            case "/abs/start": .redirect(to: "https://\(otherHost)/x")
            case "/abs/back": .redirect(to: "https://\(originHost)/abs/final")
            default: .json("{}")
            }
        }
        let other = StubServer(host: otherHost) { _ in .redirect(to: "https://\(originHost)/abs/back") }
        let client = try makeClient(origin)

        _ = try await client.send(Endpoint<EmptyResponse>(.get, "/start"))

        #expect(other.requests.count == 1)
        let back = try #require(origin.requests(path: "/abs/back").first)
        let final = try #require(origin.requests(path: "/abs/final").first)
        #expect(!hasCredentials(other.requests.first))
        #expect(!hasCredentials(back))
        #expect(!hasCredentials(final))
        #expect(final.httpShouldHandleCookies == false)
    }

    @Test func strippedRedirectDoesNotUseCookieJar() async throws {
        let server = StubServer { request in
            request.url?.port == nil ? .redirect(to: "https://\(request.url?.host() ?? ""):8443/b") : .json("{}")
        }
        let client = try makeClient(server)
        let jar = try #require(client.cookieStorage)
        let cookie = try #require(
            HTTPCookie(properties: [.domain: server.host, .path: "/", .name: "connect.sid", .value: "session"]))
        jar.setCookie(cookie)
        let jarURL = try #require(URL(string: "https://\(server.host):8443/b"))
        #expect(jar.cookies(for: jarURL)?.isEmpty == false)

        _ = try await client.send(Endpoint<EmptyResponse>(.get, "/a"))

        let first = try #require(server.requests.first)
        let stripped = try #require(server.requests.last)
        #expect(first.httpShouldHandleCookies)
        #expect(stripped.url?.port == 8443)
        #expect(stripped.httpShouldHandleCookies == false)
        #expect(stripped.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(!hasCredentials(stripped))
    }

    @Test func crossOrigin307KeepsMethodAndBody() async throws {
        let other = StubServer { _ in .json("{}") }
        let server = StubServer { _ in .redirect(to: "https://\(other.host)/upload", status: 307) }
        let client = try makeClient(server)

        _ = try await client.send(Endpoint<EmptyResponse>(.post, "/a", body: ["name": "value"]))

        let followed = try #require(other.requests.first)
        #expect(followed.httpMethod == "POST")
        #expect(followed.httpBody == Data(#"{"name":"value"}"#.utf8))
        #expect(followed.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(!hasCredentials(followed))
    }

    /// Any POST (a session sync, a bookmark) is refused rather than turned into a GET whose
    /// reply would look like its result; a 307 or 308 re-posts the body, and GETs still follow.
    @Test(arguments: [301, 302, 303]) func methodChangingRedirectIsRefused(status: Int) async throws {
        let server = StubServer { request in
            request.url?.path() == "/abs/a"
                ? .redirect(to: "https://\(request.url?.host() ?? "")/abs/b", status: status) : .json("{}")
        }
        let client = try makeClient(server)

        await #expect(throws: APIError.redirectRefused(status: status)) {
            try await client.send(Endpoint<EmptyResponse>(.post, "/a", body: ["name": "value"]))
        }
        #expect(server.requests(path: "/abs/b").isEmpty)
        _ = try await client.send(Endpoint<EmptyResponse>(.get, "/a"))
        #expect(server.requests(path: "/abs/b").first?.httpMethod == "GET")
    }

    @Test(arguments: [307, 308]) func methodKeepingRedirectRepostsTheBody(status: Int) async throws {
        let server = StubServer { request in
            request.url?.path() == "/abs/a"
                ? .redirect(to: "https://\(request.url?.host() ?? "")/abs/b", status: status) : .json("{}")
        }

        _ = try await makeClient(server).send(Endpoint<EmptyResponse>(.post, "/a", body: ["name": "value"]))

        let followed = try #require(server.requests(path: "/abs/b").first)
        #expect(followed.httpMethod == "POST")
        #expect(followed.httpBody == Data(#"{"name":"value"}"#.utf8))
        #expect(followed.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "proxy-secret")
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
}
