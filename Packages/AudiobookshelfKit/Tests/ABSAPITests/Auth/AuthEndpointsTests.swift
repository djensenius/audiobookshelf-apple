import ABSCore
import Foundation
import Testing

@testable import ABSAPI

/// A `POST /login` (or `/api/authorize` when `tokens` is false) response from a server at
/// `version`.
func authResponseJSON(version: String = "2.26.0", tokens: Bool = true) -> String {
    let tokenFields = tokens ? #","accessToken":"access-new","refreshToken":"refresh-new""# : ""
    return """
        {"user":{"id":"usr-1","username":"david","type":"admin","token":null\(tokenFields)},\
        "userDefaultLibraryId":"lib1","serverSettings":{"version":"\(version)","language":"en-us"}}
        """
}

private func makeClient(_ server: StubServer, tokens: InMemoryTokenProvider = InMemoryTokenProvider()) throws
    -> APIClient
{
    APIClient(
        configuration: try APIClientConfiguration(baseURL: server.baseURL, customHeaders: ["X-Proxy": "proxy"]),
        tokenProvider: tokens,
        sessionConfiguration: server.sessionConfiguration()
    )
}

@Suite struct AuthEndpointsTests {
    @Test func endpointShapes() {
        let status = AuthEndpoints.status()
        #expect(status.method == .get && status.path == "/status" && !status.requiresAuthentication)
        #expect(status.timeout == 10)
        let ping = AuthEndpoints.ping()
        #expect(ping.method == .get && ping.path == "/ping" && !ping.requiresAuthentication)
        let login = AuthEndpoints.login(username: "david", password: "pw")
        #expect(login.method == .post && login.path == "/login" && !login.requiresAuthentication)
        #expect(login.headers == ["x-return-tokens": "true"])
        #expect(!login.followsRedirects)
        let authorize = AuthEndpoints.authorize()
        #expect(authorize.method == .post && authorize.path == "/api/authorize" && authorize.requiresAuthentication)
        #expect(!authorize.followsRedirects)
        let logout = AuthEndpoints.logout(refreshToken: "refresh-1")
        #expect(logout.method == .post && logout.path == "/logout" && !logout.requiresAuthentication)
        #expect(logout.headers == ["x-refresh-token": "refresh-1"])
        #expect(!logout.sendsCookies && status.sendsCookies && login.sendsCookies)
    }

    @Test func pingDecodes() async throws {
        let server = StubServer { _ in .json(#"{"success":true}"#) }
        #expect(try await makeClient(server).send(AuthEndpoints.ping()) == PingResponse(success: true))
        let request = try #require(server.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-Proxy") == "proxy")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func loginSendsCredentialsReturnTokensHeaderAndCustomHeaders() async throws {
        let server = StubServer { _ in .json(authResponseJSON()) }
        let response = try await makeClient(server).send(AuthEndpoints.login(username: "david", password: "p@ss"))

        let request = try #require(server.requests(path: "/abs/login").first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-return-tokens") == "true")
        #expect(request.value(forHTTPHeaderField: "X-Proxy") == "proxy")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(body == ["username": "david", "password": "p@ss"])
        #expect(response.sessionTokens == ABSAPI.AuthTokens(accessToken: "access-new", refreshToken: "refresh-new"))
    }

    @Test func sessionTokensNeedBothTokens() throws {
        let decoder = JSONDecoder()
        let authorize = try decoder.decode(AuthResponse.self, from: Data(authResponseJSON(tokens: false).utf8))
        #expect(authorize.sessionTokens == nil)
        let accessOnly = """
            {"user":{"id":"usr-1","username":"david","accessToken":"access-new"}}
            """
        #expect(try decoder.decode(AuthResponse.self, from: Data(accessOnly.utf8)).sessionTokens == nil)
    }

    @Test func logoutSendsRefreshTokenWithoutAccessToken() async throws {
        let server = StubServer { _ in .json(#"{"redirect_url":null}"#) }
        let response = try await makeClient(server).send(AuthEndpoints.logout(refreshToken: "refresh-1"))

        #expect(response == LogoutResponse(redirectURL: nil))
        let request = try #require(server.requests(path: "/abs/logout").first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-refresh-token") == "refresh-1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    /// Stub protocols never see the jar's `Cookie` header, so this checks the request's
    /// cookie handling flag, which is what keeps the jar's `refresh_token` cookie off the request.
    @Test func logoutIsSentWithoutCookies() async throws {
        let server = StubServer { request in
            request.url?.path() == "/abs/logout" ? .json(#"{"redirect_url":null}"#) : .json(#"{"success":true}"#)
        }
        let client = try makeClient(server)

        _ = try await client.send(AuthEndpoints.ping())
        _ = try await client.send(AuthEndpoints.logout(refreshToken: "refresh-1"))

        #expect(try #require(server.requests(path: "/abs/ping").first).httpShouldHandleCookies)
        let logout = try #require(server.requests(path: "/abs/logout").first)
        #expect(!logout.httpShouldHandleCookies)
        #expect(logout.value(forHTTPHeaderField: "x-refresh-token") == "refresh-1")
    }

    @Test func tokensAreRedacted() {
        let tokens = ABSAPI.AuthTokens(accessToken: "secret-access", refreshToken: "secret-refresh")
        var dumped = ""
        dump(tokens, to: &dumped)
        for text in [String(describing: tokens), String(reflecting: tokens), dumped, "\(tokens)"] {
            #expect(!text.contains("secret-access") && !text.contains("secret-refresh"))
            #expect(text.contains("<redacted>"))
        }
    }

    @Test func logoutDecodesOpenIDRedirect() async throws {
        let server = StubServer { _ in .json(#"{"redirect_url":"https://idp.example/logout"}"#) }
        let response = try await makeClient(server).send(AuthEndpoints.logout(refreshToken: "refresh-1"))
        #expect(response.redirectURL == "https://idp.example/logout")
    }

    @Test func authorizeUsesAccessToken() async throws {
        let server = StubServer { _ in .json(authResponseJSON(tokens: false)) }
        let response = try await makeClient(server).send(AuthEndpoints.authorize())

        #expect(response.user.id == "usr-1")
        let request = try #require(server.requests(path: "/abs/api/authorize").first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
    }
}
