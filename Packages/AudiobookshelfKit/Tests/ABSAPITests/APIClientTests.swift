import Foundation
import Testing

@testable import ABSAPI

private struct Library: Decodable, Sendable, Equatable {
    let id: String
    let name: String
}

private struct ProgressUpdate: Encodable, Sendable {
    let currentTime: Double
    let isFinished: Bool
}

private func makeClient(
    _ server: StubServer,
    tokens: InMemoryTokenProvider = InMemoryTokenProvider(),
    customHeaders: [String: String] = [:]
) throws -> APIClient {
    APIClient(
        configuration: try APIClientConfiguration(baseURL: server.baseURL, customHeaders: customHeaders),
        tokenProvider: tokens,
        sessionConfiguration: server.sessionConfiguration()
    )
}

@Suite struct APIClientRequestTests {
    @Test func injectsCustomHeadersTokenAndBody() async throws {
        let server = StubServer { _ in .json(#"{"id":"lib1","name":"Books"}"#) }
        let client = try makeClient(server, customHeaders: ["CF-Access-Client-Id": "proxy-id", "X-Proxy": "1"])

        let library = try await client.send(
            Endpoint<Library>(
                .patch, "/api/libraries/lib1",
                query: [URLQueryItem(name: "include", value: "filterdata")],
                headers: ["x-return-tokens": "true"],
                body: ProgressUpdate(currentTime: 12.5, isFinished: false)
            )
        )

        #expect(library == Library(id: "lib1", name: "Books"))
        let request = try #require(server.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.absoluteString == "https://\(server.host)/abs/api/libraries/lib1?include=filterdata")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "proxy-id")
        #expect(request.value(forHTTPHeaderField: "X-Proxy") == "1")
        #expect(request.value(forHTTPHeaderField: "x-return-tokens") == "true")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["currentTime"] as? Double == 12.5)
        #expect(json["isFinished"] as? Bool == false)
    }

    @Test func updatedCustomHeadersApplyToLaterRequests() async throws {
        let server = StubServer { _ in .text("OK", status: 200) }
        let client = try makeClient(server, customHeaders: ["X-Old": "1"])

        try await client.setCustomHeaders(["X-New": "2"])
        _ = try await client.send(Endpoint<EmptyResponse>(.post, "/api/me/sync"))

        let request = try #require(server.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-Old") == nil)
        #expect(request.value(forHTTPHeaderField: "X-New") == "2")
    }

    @Test func unauthenticatedEndpointSendsNoToken() async throws {
        let server = StubServer { _ in .json("{}") }
        let client = try makeClient(server, customHeaders: ["X-Proxy": "1"])

        _ = try await client.send(Endpoint<EmptyResponse>(.get, "/ping", requiresAuthentication: false))

        let request = try #require(server.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Proxy") == "1")
    }

    @Test func authenticatedEndpointWithoutTokensFails() async throws {
        let server = StubServer { _ in .json("{}") }
        let client = try makeClient(server, tokens: InMemoryTokenProvider(nil))

        await #expect(throws: APIError.notAuthenticated) {
            try await client.send(Endpoint<EmptyResponse>(.get, "/api/libraries"))
        }
        #expect(server.requests.isEmpty)
    }

    @Test func endpointTimeoutOverridesDefault() async throws {
        let server = StubServer { _ in .json("{}") }
        let client = try makeClient(server)

        _ = try await client.send(Endpoint<EmptyResponse>(.get, "/a"))
        _ = try await client.send(Endpoint<EmptyResponse>(.get, "/b", timeout: 5))

        #expect(server.requests.map(\.timeoutInterval) == [30, 5])
    }

    @Test func returnsRawDataUnparsed() async throws {
        let server = StubServer { _ in .text("not json", status: 200) }
        let client = try makeClient(server)

        let data = try await client.send(Endpoint<Data>(.get, "/api/items/1/ebook"))

        #expect(String(decoding: data, as: UTF8.self) == "not json")
    }

    @Test func suppressedRedirectReturnsLocation() async throws {
        let server = StubServer { _ in .redirect(to: "https://idp.example/authorize?state=abc") }
        let client = try makeClient(server)

        let response = try await client.response(
            for: Endpoint<EmptyResponse>(
                .get, "/auth/openid", requiresAuthentication: false, followsRedirects: false)
        )

        #expect(response.httpResponse.statusCode == 302)
        #expect(
            response.httpResponse.value(forHTTPHeaderField: "Location") == "https://idp.example/authorize?state=abc")
        #expect(server.requests.count == 1)
    }
}

@Suite struct APIClientURLTests {
    @Test(arguments: [
        ("https://abs.example.com", "/api/libraries", "https://abs.example.com/api/libraries"),
        ("https://abs.example.com/", "/api/libraries", "https://abs.example.com/api/libraries"),
        ("https://example.com/abs", "/api/libraries", "https://example.com/abs/api/libraries"),
        ("https://example.com/abs/", "api/libraries", "https://example.com/abs/api/libraries"),
        ("http://192.168.1.2:13378/a/b", "/ping", "http://192.168.1.2:13378/a/b/ping"),
    ])
    func appendsPathToBaseSubpath(base: String, path: String, expected: String) throws {
        let url = try APIClient.url(base: try #require(URL(string: base)), path: path, query: [])
        #expect(url.absoluteString == expected)
    }

    @Test func keepsEscapesInPathAndEncodesTheRest() throws {
        let base = try #require(URL(string: "https://example.com/my%20abs"))
        let url = try APIClient.url(base: base, path: "/api/items/a%2Fb/x y%zz", query: [])
        #expect(url.absoluteString == "https://example.com/my%20abs/api/items/a%2Fb/x%20y%25zz")
    }

    @Test func encodesQueryValues() throws {
        let base = try #require(URL(string: "https://example.com/abs"))
        let url = try APIClient.url(
            base: base, path: "/api/libraries/l1/items",
            query: [
                URLQueryItem(name: "filter", value: "genres.U2NpLUZp+/="),
                URLQueryItem(name: "q", value: "a b&c"),
            ])
        #expect(
            url.absoluteString
                == "https://example.com/abs/api/libraries/l1/items?filter=genres.U2NpLUZp%2B/%3D&q=a%20b%26c")
    }
}

@Suite struct APIClientErrorTests {
    @Test(arguments: [
        (
            StubResponse.text("Invalid username or password", status: 401),
            APIError.unauthorized(message: "Invalid username or password")
        ),
        (StubResponse.text("Forbidden", status: 403), APIError.forbidden(message: "Forbidden")),
        (StubResponse.text("Not Found", status: 404), APIError.notFound),
        (StubResponse.text("Internal error\n", status: 500), APIError.http(status: 500, message: "Internal error")),
        (StubResponse(status: 502), APIError.http(status: 502, message: nil)),
        (StubResponse.failure(.notConnectedToInternet), APIError.network(.notConnectedToInternet)),
        (StubResponse.failure(.timedOut), APIError.timedOut),
    ])
    func mapsResponsesToErrors(stub: StubResponse, expected: APIError) async throws {
        let server = StubServer { _ in stub }
        let client = try makeClient(server)

        await #expect(throws: expected) {
            try await client.send(Endpoint<EmptyResponse>(.post, "/login", requiresAuthentication: false))
        }
    }

    @Test func malformedBodyIsDecodingError() async throws {
        let server = StubServer { _ in .json(#"{"id":"lib1"}"#) }
        let client = try makeClient(server)

        await #expect {
            try await client.send(Endpoint<Library>(.get, "/api/libraries/lib1"))
        } throws: { error in
            guard case .decoding = error as? APIError else { return false }
            return true
        }
    }

    @Test func cancelledRequestThrowsCancellation() async throws {
        let server = StubServer { _ in .failure(.cancelled) }
        let client = try makeClient(server)

        await #expect(throws: CancellationError.self) {
            try await client.send(Endpoint<EmptyResponse>(.get, "/api/libraries"))
        }
    }
}

@Suite struct APIClientCookieTests {
    @Test func eachConnectionHasItsOwnCookieJar() throws {
        let server = StubServer { _ in .json("{}") }
        let first = try makeClient(server)
        let second = try makeClient(server)

        let firstJar = try #require(first.cookieStorage)
        let secondJar = try #require(second.cookieStorage)
        #expect(firstJar !== HTTPCookieStorage.shared)
        #expect(firstJar !== secondJar)

        let cookie = try #require(
            HTTPCookie(properties: [
                .domain: server.host, .path: "/", .name: "connect.sid", .value: "oidc-session",
            ]))
        firstJar.setCookie(cookie)

        #expect(firstJar.cookies(for: server.baseURL)?.map(\.value) == ["oidc-session"])
        #expect(secondJar.cookies(for: server.baseURL)?.isEmpty ?? true)
    }

    @Test func usesAnInjectedCookieJar() throws {
        let server = StubServer { _ in .json("{}") }
        let jar = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: server.baseURL), tokenProvider: InMemoryTokenProvider(),
            sessionConfiguration: server.sessionConfiguration(), cookieStorage: jar)
        #expect(client.cookieStorage === jar)
    }

    @Test func reusedConfigurationGetsFreshCookieJars() throws {
        let server = StubServer { _ in .json("{}") }
        let configuration = server.sessionConfiguration()
        configuration.httpCookieStorage = .shared
        let settings = try APIClientConfiguration(baseURL: server.baseURL)

        let first = APIClient(
            configuration: settings, tokenProvider: InMemoryTokenProvider(), sessionConfiguration: configuration)
        let second = APIClient(
            configuration: settings, tokenProvider: InMemoryTokenProvider(), sessionConfiguration: configuration)

        let firstJar = try #require(first.cookieStorage)
        let secondJar = try #require(second.cookieStorage)
        #expect(firstJar !== HTTPCookieStorage.shared)
        #expect(secondJar !== HTTPCookieStorage.shared)
        #expect(firstJar !== secondJar)
    }
}

@Suite struct CustomHeaderValidationTests {
    @Test(arguments: [
        "Authorization", "authorization", "COOKIE", "Cookie", "X-Refresh-Token", "Proxy-Authorization", "Host",
        "Connection", "Transfer-Encoding", "content-length", "TE", "Upgrade",
    ])
    func rejectsReservedHeaders(name: String) throws {
        let url = try #require(URL(string: "https://example.com"))
        #expect(throws: CustomHeaderError.reserved(name: name)) {
            try APIClientConfiguration(baseURL: url, customHeaders: ["X-Proxy": "1", name: "secret"])
        }
    }

    @Test func setCustomHeadersRejectsReservedHeaderAndKeepsOldOnes() async throws {
        let server = StubServer { _ in .json("{}") }
        let client = try makeClient(server, customHeaders: ["X-Proxy": "1"])

        await #expect(throws: CustomHeaderError.reserved(name: "Authorization")) {
            try await client.setCustomHeaders(["Authorization": "Basic abc"])
        }
        _ = try await client.send(Endpoint<EmptyResponse>(.get, "/ping"))

        let request = try #require(server.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-Proxy") == "1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
    }

    @Test func reservedHeaderErrorSuggestsAlternative() {
        let description = CustomHeaderError.reserved(name: "Cookie").errorDescription ?? ""
        #expect(description.contains("Cookie"))
        #expect(description.contains("service token"))
        #expect(
            CustomHeaderError.reserved(name: "Host").errorDescription?.contains("managed by the connection") == true)
    }
}
