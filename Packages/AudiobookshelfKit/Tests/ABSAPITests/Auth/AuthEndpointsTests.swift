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
        #expect(logout.sendsCookies && logout.withheldCookies == ["refresh_token"])
        #expect(status.sendsCookies && login.sendsCookies && status.withheldCookies.isEmpty)
        #expect(logout.followsRedirects && logout.staysOnOrigin)
        #expect(!status.staysOnOrigin && !AuthEndpoints.ping().staysOnOrigin && !login.staysOnOrigin)
        #expect(!authorize.staysOnOrigin && !Endpoint<EmptyResponse>(.get, "/api/me").staysOnOrigin)
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

    /// The client writes the logout's `Cookie` header itself (stub protocols never see the
    /// jar's own header): every cookie in the jar except `refresh_token`.
    @Test func logoutSendsProxyCookiesButNotTheRefreshToken() async throws {
        let server = StubServer { request in
            request.url?.path() == "/abs/logout" ? .json(#"{"redirect_url":null}"#) : .json(#"{"success":true}"#)
        }
        let client = try makeClient(server)
        let jar = try #require(client.cookieStorage)
        for (name, value) in [("lb", "1"), ("refresh_token", "cookie-token"), ("connect.sid", "s%3Aabc")] {
            jar.setCookie(
                try #require(
                    HTTPCookie(properties: [.name: name, .value: value, .domain: server.host, .path: "/"])))
        }

        _ = try await client.send(AuthEndpoints.ping())
        _ = try await client.send(AuthEndpoints.logout(refreshToken: "refresh-1"))

        #expect(try #require(server.requests(path: "/abs/ping").first).httpShouldHandleCookies)
        let logout = try #require(server.requests(path: "/abs/logout").first)
        #expect(!logout.httpShouldHandleCookies)
        let cookies = try #require(logout.value(forHTTPHeaderField: "Cookie"))
        #expect(Set(cookies.components(separatedBy: "; ")) == ["lb=1", "connect.sid=s%3Aabc"])
        #expect(logout.value(forHTTPHeaderField: "x-refresh-token") == "refresh-1")
    }

    @Test func endpointCookieIsCombinedWithTheJar() async throws {
        let server = StubServer { _ in .json(#"{"redirect_url":null}"#) }
        let client = try makeClient(server)
        let jar = try #require(client.cookieStorage)
        for (name, value) in [("lb", "1"), ("auth_method", "stale"), ("refresh_token", "cookie-token")] {
            jar.setCookie(
                try #require(
                    HTTPCookie(properties: [.name: name, .value: value, .domain: server.host, .path: "/"])))
        }
        var logout = AuthEndpoints.logout(refreshToken: "refresh-1")
        logout.headers["cookie"] = "auth_method=openid; openid_id_token=id"

        _ = try await client.send(logout)

        let request = try #require(server.requests(path: "/abs/logout").first)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "lb=1; auth_method=openid; openid_id_token=id")
        #expect(request.value(forHTTPHeaderField: "x-refresh-token") == "refresh-1")
    }

    @Test func logoutWithAnEmptyJarSendsNoCookies() async throws {
        let server = StubServer { _ in .json(#"{"redirect_url":null}"#) }
        let client = try makeClient(server)
        let jar = try #require(client.cookieStorage)
        jar.setCookie(
            try #require(
                HTTPCookie(properties: [.name: "refresh_token", .value: "t", .domain: server.host, .path: "/"])))

        _ = try await client.send(AuthEndpoints.logout(refreshToken: "refresh-1"))
        #expect(jar.cookies?.count == 1)
        jar.cookies?.forEach(jar.deleteCookie)
        _ = try await client.send(AuthEndpoints.logout(refreshToken: "refresh-1"))

        for logout in server.requests(path: "/abs/logout") {
            #expect(logout.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(!logout.httpShouldHandleCookies)
        }
        #expect(server.requests(path: "/abs/logout").count == 2)
    }

    /// A same-origin 307/308 keeps the method, body, refresh token and the client-written cookies.
    @Test(arguments: [307, 308]) func logoutFollowsSameOriginRedirects(status: Int) async throws {
        let server = StubServer { request in
            request.url?.path() == "/abs/logout"
                ? .redirect(to: "https://\(request.url?.host() ?? "")/abs/v2/logout", status: status)
                : .json(#"{"redirect_url":null}"#)
        }
        let client = try makeClient(server)
        let jar = try #require(client.cookieStorage)
        for (name, value) in [("lb", "1"), ("refresh_token", "cookie-token")] {
            jar.setCookie(
                try #require(
                    HTTPCookie(properties: [.name: name, .value: value, .domain: server.host, .path: "/"])))
        }

        let response = try await client.send(AuthEndpoints.logout(refreshToken: "refresh-1"))

        #expect(response == LogoutResponse(redirectURL: nil))
        let followed = try #require(server.requests(path: "/abs/v2/logout").first)
        #expect(followed.httpMethod == "POST")
        #expect(followed.value(forHTTPHeaderField: "x-refresh-token") == "refresh-1")
        #expect(followed.value(forHTTPHeaderField: "Cookie") == "lb=1")
        #expect(!followed.httpShouldHandleCookies)
    }

    /// A hop off the origin would lose the refresh token, so its reply can't confirm a logout:
    /// the redirect is declined and fails instead of reporting success.
    @Test(arguments: [302, 307, 308]) func logoutRefusesCrossOriginRedirects(status: Int) async throws {
        let other = StubServer { _ in .json(#"{"redirect_url":null}"#) }
        let server = StubServer { _ in .redirect(to: "https://\(other.host)/logout", status: status) }
        let client = try makeClient(server)

        await #expect(throws: APIError.redirectRefused(status: status)) {
            try await client.send(AuthEndpoints.logout(refreshToken: "refresh-1"))
        }
        #expect(other.requests.isEmpty)
        #expect(server.requests.count == 1)
    }

    /// The same-host port change and `http` → `https` upgrade on another host are off the origin too.
    /// A proxy cookie set on a same-origin redirect is stored and sent on the next hop, with the
    /// jar's other cookies and the endpoint's own, and still without `refresh_token`.
    @Test func logoutRedirectCarriesTheProxyCookie() async throws {
        let server = StubServer { request in
            guard request.url?.path() == "/abs/logout" else { return .json(#"{"redirect_url":null}"#) }
            var redirect = StubResponse.redirect(to: "https://\(request.url?.host() ?? "")/abs/v2/logout")
            redirect.headers["Set-Cookie"] = "proxy_session=abc; Path=/"
            return redirect
        }
        let client = try makeClient(server)
        let jar = try #require(client.cookieStorage)
        for (name, value) in [("lb", "1"), ("refresh_token", "cookie-token"), ("auth_method", "stale")] {
            jar.setCookie(
                try #require(
                    HTTPCookie(properties: [.name: name, .value: value, .domain: server.host, .path: "/"])))
        }
        var logout = AuthEndpoints.logout(refreshToken: "refresh-1")
        logout.headers["Cookie"] = "auth_method=openid"

        _ = try await client.send(logout)

        let first = try #require(server.requests(path: "/abs/logout").first)
        let followed = try #require(server.requests(path: "/abs/v2/logout").first)
        #expect(first.value(forHTTPHeaderField: "Cookie") == "lb=1; auth_method=openid")
        let cookies = try #require(followed.value(forHTTPHeaderField: "Cookie"))
        #expect(cookies.hasSuffix("; auth_method=openid"))
        #expect(
            Set(cookies.components(separatedBy: "; ")) == ["lb=1", "proxy_session=abc", "auth_method=openid"])
        #expect(followed.value(forHTTPHeaderField: "x-refresh-token") == "refresh-1")
        #expect(!followed.httpShouldHandleCookies)
        #expect(jar.cookies?.contains { $0.name == "proxy_session" && $0.value == "abc" } == true)
    }

    /// A proxy that sets its cookie and redirects back to the same URL gets it on the retry; a
    /// `refresh_token` set by the redirect is neither stored nor sent.
    @Test func logoutRedirectToTheSameURLCarriesTheProxyCookie() async throws {
        let server = StubServer { request in
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            guard !cookie.contains("proxy_session=abc") else { return .json(#"{"redirect_url":null}"#) }
            var redirect = StubResponse.redirect(to: request.url?.absoluteString ?? "", status: 307)
            redirect.headers["Set-Cookie"] = "proxy_session=abc; Path=/, refresh_token=planted; Path=/"
            return redirect
        }
        let client = try makeClient(server)

        let response = try await client.send(AuthEndpoints.logout(refreshToken: "refresh-1"))

        #expect(response == LogoutResponse(redirectURL: nil))
        let requests = server.requests(path: "/abs/logout")
        #expect(requests.count == 2)
        #expect(requests.first?.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(requests.last?.value(forHTTPHeaderField: "Cookie") == "proxy_session=abc")
        #expect(requests.last?.httpMethod == "POST")
        #expect(client.cookieStorage?.cookies?.contains { $0.name == "refresh_token" } == false)
    }

    /// A cookie set on a redirect off the origin is neither followed nor stored.
    @Test func logoutCrossOriginRedirectStoresNoCookie() async throws {
        let other = StubServer { _ in .json(#"{"redirect_url":null}"#) }
        let server = StubServer { _ in
            var redirect = StubResponse.redirect(to: "https://\(other.host)/logout", status: 307)
            redirect.headers["Set-Cookie"] = "proxy_session=abc; Path=/"
            return redirect
        }
        let client = try makeClient(server)

        await #expect(throws: APIError.redirectRefused(status: 307)) {
            try await client.send(AuthEndpoints.logout(refreshToken: "refresh-1"))
        }
        #expect(other.requests.isEmpty)
        #expect(client.cookieStorage?.cookies?.isEmpty == true)
    }

    @Test func logoutRefusesPortChangesAndOtherHostUpgrades() async throws {
        let other = StubServer { _ in .json(#"{"redirect_url":null}"#) }
        let portChange = StubServer { request in
            request.url?.port == nil
                ? .redirect(to: "https://\(request.url?.host() ?? ""):8443/abs/logout", status: 307)
                : .json(#"{"redirect_url":null}"#)
        }
        let upgrade = StubServer { _ in .redirect(to: "https://\(other.host)/abs/logout", status: 308) }
        let upgradeClient = APIClient(
            configuration: try APIClientConfiguration(baseURL: #require(URL(string: "http://\(upgrade.host)/abs"))),
            tokenProvider: InMemoryTokenProvider(), sessionConfiguration: upgrade.sessionConfiguration())

        await #expect(throws: APIError.redirectRefused(status: 307)) {
            try await makeClient(portChange).send(AuthEndpoints.logout(refreshToken: "refresh-1"))
        }
        await #expect(throws: APIError.redirectRefused(status: 308)) {
            try await upgradeClient.send(AuthEndpoints.logout(refreshToken: "refresh-1"))
        }
        #expect(portChange.requests.count == 1)
        #expect(other.requests.isEmpty)
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
