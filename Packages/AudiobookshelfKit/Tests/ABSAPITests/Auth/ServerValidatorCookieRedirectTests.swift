import Foundation
import Testing

@testable import ABSAPI

private let statusJSON = """
    {"app":"audiobookshelf","serverVersion":"2.26.0","isInit":true,"language":"en-us","authMethods":["local"]}
    """

/// Whether `request` carries the proxy's `lb=1` cookie.
private func hasProxyCookie(_ request: URLRequest?) -> Bool {
    let cookies = request?.value(forHTTPHeaderField: "Cookie") ?? ""
    return cookies.split(separator: ";").contains { $0.trimmingCharacters(in: .whitespaces) == "lb=1" }
}

/// A proxy's redirect from `url` to `location` (resolved against `url`), setting `setCookie`.
private func proxyRedirect(
    from url: URL?, to location: String, status: Int = 302, setCookie: String? = "lb=1; Path=/"
) -> StubResponse {
    var headers = ["Location": location]
    headers["Set-Cookie"] = setCookie
    return StubResponse(
        status: status, headers: headers, redirect: URL(string: location, relativeTo: url)?.absoluteURL)
}

/// A new account client for `server`, as on launch: tokens, custom headers and an empty jar,
/// which the stub honours (it sends the jar's cookies and stores `Set-Cookie`).
private func accountClient(_ server: StubServer) throws -> APIClient {
    let client = APIClient(
        configuration: try APIClientConfiguration(baseURL: server.baseURL, customHeaders: ["X-Proxy": "proxy"]),
        tokenProvider: InMemoryTokenProvider(), sessionConfiguration: server.sessionConfiguration())
    server.useCookieStorage(try #require(client.cookieStorage))
    return client
}

private func validator(_ server: StubServer) -> ServerValidator {
    ServerValidator(sessionConfiguration: { server.sessionConfiguration() })
}

/// A server whose `/login` is answered by `login`, behind a proxy that lets `/status` through.
private func loginServer(login: @escaping StubURLProtocol.Handler) -> StubServer {
    StubServer { request in
        switch request.url?.path() {
        case "/abs/status": .json(statusJSON)
        case "/abs/login": login(request)
        default: .text("Not Found", status: 404)
        }
    }
}

/// Validates `server` and signs in, with the stub honouring the validation's cookie jar.
private func signIn(_ server: StubServer) async throws -> LoginResult {
    let validator = validator(server)
    let validated = try await validator.validate(address: "https://\(server.host)/abs")
    server.useCookieStorage(try #require(validated.cookieStorage))
    return try await validator.login(to: validated, username: "david", password: "pw")
}

/// A `Set-Cookie` value the jar has never seen, so every redirect brings a new cookie.
private func freshCookie() -> String {
    "lb=\(UUID().uuidString); Path=/"
}

/// A proxy, load balancer or auth gateway that sets a cookie on first contact and redirects back
/// to the same URL gets the request once more, with the cookie (#172).
@Suite struct ServerValidatorCookieRedirectTests {
    @Test(arguments: [302, 307], [false, true])
    func authorizeRetriesASameURLCookieRedirectOnce(status: Int, relativeLocation: Bool) async throws {
        let server = StubServer { request in
            guard hasProxyCookie(request) else {
                let location = relativeLocation ? request.url?.path() : request.url?.absoluteString
                return proxyRedirect(from: request.url, to: location ?? "", status: status)
            }
            return .json(authResponseJSON(tokens: false))
        }
        let client = try accountClient(server)

        let result = try await validator(server).authorize(with: client)

        #expect(result.response.user.id == "usr-1")
        let requests = server.requests(path: "/abs/api/authorize")
        #expect(requests.count == 2)
        #expect(!hasProxyCookie(requests.first))
        let retry = try #require(requests.last)
        #expect(hasProxyCookie(retry))
        #expect(retry.httpMethod == "POST")
        #expect(retry.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        #expect(retry.value(forHTTPHeaderField: "X-Proxy") == "proxy")
    }

    /// `URLSession` might not store the cookies of a redirect it was told not to follow, so the
    /// validator stores them before retrying. This stub neither stores nor sends cookies; the
    /// proxy reads the jar.
    @Test func authorizeStoresTheRedirectCookieBeforeRetrying() async throws {
        let jar = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let server = StubServer { request in
            guard let url = request.url else { return .failure(.badURL) }
            let hasCookie = jar.cookies(for: url)?.contains { $0.name == "lb" && $0.value == "1" } == true
            return hasCookie ? .json(authResponseJSON(tokens: false)) : proxyRedirect(from: url, to: url.absoluteString)
        }
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: server.baseURL), tokenProvider: InMemoryTokenProvider(),
            sessionConfiguration: server.sessionConfiguration(), cookieStorage: jar)

        _ = try await validator(server).authorize(with: client)

        #expect(server.requests(path: "/abs/api/authorize").count == 2)
    }

    /// Only a redirect to exactly the request URL is retried, whatever cookies it sets.
    @Test(arguments: [
        "https://{host}/abs/api/authorize/", "https://{host}/abs/api/authorize?lb=1", "/abs/login",
        "http://{host}/abs/api/authorize", "https://{host}:8443/abs/api/authorize",
        "https://elsewhere.stub.test/abs/api/authorize",
    ])
    func authorizeDoesNotRetryARedirectElsewhere(location: String) async throws {
        let server = StubServer { request in
            hasProxyCookie(request)
                ? .json(authResponseJSON(tokens: false))
                : proxyRedirect(
                    from: request.url, to: location.replacingOccurrences(of: "{host}", with: request.url?.host() ?? ""))
        }
        let client = try accountClient(server)

        await #expect(throws: ServerValidationError.loginRedirected) {
            try await validator(server).authorize(with: client)
        }
        #expect(server.requests.count == 1)
    }

    @Test(arguments: [302, 307]) func authorizeDoesNotRetryASameURLRedirectWithoutCookies(status: Int) async throws {
        let server = StubServer { request in
            proxyRedirect(from: request.url, to: request.url?.absoluteString ?? "", status: status, setCookie: nil)
        }
        let client = try accountClient(server)

        await #expect(throws: ServerValidationError.loginRedirected) {
            try await validator(server).authorize(with: client)
        }
        #expect(server.requests.count == 1)
    }

    /// A proxy that keeps redirecting, with a new cookie each time, gets one retry, not a loop.
    @Test func authorizeRetriesOnlyOnce() async throws {
        let server = StubServer { request in
            proxyRedirect(from: request.url, to: request.url?.absoluteString ?? "", setCookie: freshCookie())
        }
        let client = try accountClient(server)

        await #expect(throws: ServerValidationError.loginRedirected) {
            try await validator(server).authorize(with: client)
        }
        #expect(server.requests(path: "/abs/api/authorize").count == 2)
    }

    /// The jar already holds `lb=1`. A cookie the retry wouldn't send, or would send unchanged,
    /// gives no reason to send the request again.
    @Test(arguments: [
        "lb=1; Path=/", "lb=2; Path=/other", "lb=; Max-Age=0; Path=/", "lb=2; Domain=other.example; Path=/",
    ])
    func authorizeDoesNotRetryForACookieItWouldNotSend(setCookie: String) async throws {
        let server = StubServer { request in
            proxyRedirect(from: request.url, to: request.url?.absoluteString ?? "", setCookie: setCookie)
        }
        let client = try accountClient(server)
        let jar = try #require(client.cookieStorage)
        jar.setCookie(
            try #require(HTTPCookie(properties: [.name: "lb", .value: "1", .domain: server.host, .path: "/"])))

        await #expect(throws: ServerValidationError.loginRedirected) {
            try await validator(server).authorize(with: client)
        }
        #expect(server.requests.count == 1)
    }

    /// A 303 says the request was handled, so it is never sent again, even with a new cookie.
    @Test func seeOtherIsNeverRetried() async throws {
        let seeOther: StubURLProtocol.Handler = { request in
            proxyRedirect(from: request.url, to: request.url?.absoluteString ?? "", status: 303)
        }
        let server = StubServer(handler: seeOther)
        let client = try accountClient(server)
        await #expect(throws: ServerValidationError.loginRedirected) {
            try await validator(server).authorize(with: client)
        }
        #expect(server.requests.count == 1)

        let login = loginServer(login: seeOther)
        await #expect(throws: ServerValidationError.loginRedirected) {
            try await signIn(login)
        }
        #expect(login.requests(path: "/abs/login").count == 1)
    }

    /// The password is only re-sent to the URL it was posted to.
    @Test func loginRetriesASameURLCookieRedirectOnce() async throws {
        let server = loginServer { request in
            hasProxyCookie(request)
                ? .json(authResponseJSON()) : proxyRedirect(from: request.url, to: request.url?.absoluteString ?? "")
        }

        let result = try await signIn(server)

        #expect(result.tokens.accessToken == "access-new")
        let logins = server.requests(path: "/abs/login")
        #expect(logins.count == 2)
        #expect(!hasProxyCookie(logins.first))
        let retry = try #require(logins.last)
        #expect(hasProxyCookie(retry))
        #expect(retry.httpMethod == "POST")
        let body = try JSONSerialization.jsonObject(with: try #require(retry.httpBody)) as? [String: String]
        #expect(body == ["username": "david", "password": "pw"])
        #expect(retry.value(forHTTPHeaderField: "x-return-tokens") == "true")
    }

    @Test(arguments: [302, 307]) func loginDoesNotRetryASameURLRedirectWithoutCookies(status: Int) async throws {
        let server = loginServer { request in
            proxyRedirect(from: request.url, to: request.url?.absoluteString ?? "", status: status, setCookie: nil)
        }

        await #expect(throws: ServerValidationError.loginRedirected) {
            try await signIn(server)
        }
        #expect(server.requests(path: "/abs/login").count == 1)
    }

    @Test(arguments: ["/abs/login/", "/abs/login?lb=1", "https://elsewhere.stub.test/abs/login"])
    func loginDoesNotRetryACookieRedirectElsewhere(location: String) async throws {
        let server = loginServer { request in
            hasProxyCookie(request) ? .json(authResponseJSON()) : proxyRedirect(from: request.url, to: location)
        }

        await #expect(throws: ServerValidationError.loginRedirected) {
            try await signIn(server)
        }
        #expect(server.requests(path: "/abs/login").count == 1)
    }

    /// A login that keeps redirecting, with a new cookie each time, is posted twice at most.
    @Test func loginRetriesOnlyOnce() async throws {
        let server = loginServer { request in
            proxyRedirect(from: request.url, to: request.url?.absoluteString ?? "", setCookie: freshCookie())
        }

        await #expect(throws: ServerValidationError.loginRedirected) {
            try await signIn(server)
        }
        #expect(server.requests(path: "/abs/login").count == 2)
    }

    /// A request that doesn't send cookies would gain nothing from a retry, and the jar isn't touched.
    @Test func requestWithoutCookiesIsNotRetried() async throws {
        let server = StubServer { request in proxyRedirect(from: request.url, to: request.url?.absoluteString ?? "") }
        let client = try accountClient(server)
        let endpoint = Endpoint<Data>(.post, "/api/authorize", followsRedirects: false, sendsCookies: false)

        let reply = try await ServerValidator.sendRetryingCookieRedirect(endpoint, client: client)

        #expect(reply.httpResponse.statusCode == 302)
        #expect(server.requests.count == 1)
        #expect(client.cookieStorage?.cookies?.isEmpty == true)
    }

    /// A withheld cookie (here `refresh_token`, as on logout) set by the redirect is neither
    /// stored nor a reason to retry; the proxy's cookie still is.
    @Test(arguments: [
        "refresh_token=planted; Path=/", "lb=1; Path=/, refresh_token=planted; Path=/",
    ])
    func withheldCookiesAreNotStoredOrRetriedFor(setCookie: String) async throws {
        let server = StubServer { request in
            hasProxyCookie(request)
                ? .json("{}")
                : proxyRedirect(from: request.url, to: request.url?.absoluteString ?? "", setCookie: setCookie)
        }
        let client = try accountClient(server)
        let endpoint = Endpoint<Data>(
            .post, "/api/authorize", followsRedirects: false, withheldCookies: ["refresh_token"])

        let reply = try await ServerValidator.sendRetryingCookieRedirect(endpoint, client: client)

        let setsProxyCookie = setCookie.hasPrefix("lb=1")
        #expect(reply.httpResponse.statusCode == (setsProxyCookie ? 200 : 302))
        #expect(server.requests.count == (setsProxyCookie ? 2 : 1))
        #expect(
            server.requests.allSatisfy { !($0.value(forHTTPHeaderField: "Cookie") ?? "").contains("refresh_token") })
        #expect(client.cookieStorage?.cookies?.contains { $0.name == "refresh_token" } == false)
    }
}
