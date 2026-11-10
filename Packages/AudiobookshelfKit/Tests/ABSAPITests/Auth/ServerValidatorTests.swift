import ABSCore
import Foundation
import Testing

@testable import ABSAPI

private let statusLocal = """
    {"app":"audiobookshelf","serverVersion":"2.26.0","isInit":true,"language":"en-us","authMethods":["local"],\
    "authFormData":{"authLoginCustomMessage":null}}
    """

private let statusOpenID = """
    {"app":"audiobookshelf","serverVersion":"2.37.2","isInit":true,"language":"en-us",\
    "authMethods":["local","openid"],"authFormData":{"authOpenIDButtonText":"Sign in with SSO",\
    "authOpenIDAutoLaunch":false}}
    """

private func status(version: String?) -> String {
    let field = version.map { #""serverVersion":"\#($0)","# } ?? ""
    return #"{"app":"audiobookshelf",\#(field)"isInit":true,"language":"en-us","authMethods":["local"]}"#
}

private func validator(_ server: StubServer) -> ServerValidator {
    ServerValidator(sessionConfiguration: { server.sessionConfiguration() })
}

/// Answers `/status` with `statusJSON` and `/login` with `loginResponse`.
private func stubServer(status statusJSON: String = statusLocal, login loginResponse: StubResponse? = nil)
    -> StubServer
{
    StubServer { request in
        switch request.url?.path() {
        case "/abs/status": .json(statusJSON)
        case "/abs/login": loginResponse ?? .json(authResponseJSON())
        default: .text("Not Found", status: 404)
        }
    }
}

@Suite struct ServerValidatorStatusTests {
    @Test func localAuthStatus() async throws {
        let server = stubServer()
        let validated = try await validator(server).validate(address: "  https://\(server.host)/abs/ ")

        #expect(validated.address.url.absoluteString == "https://\(server.host)/abs")
        #expect(validated.status.supportsLocalLogin)
        #expect(!validated.status.supportsOpenID)
        #expect(validated.features.version == ServerVersion(2, 26, 0))
        #expect(!validated.fellBackToHTTP && !validated.isInsecure)
    }

    @Test func openIDAuthStatusSendsCustomHeaders() async throws {
        let server = stubServer(status: statusOpenID)
        let validated = try await validator(server).validate(
            address: "\(server.host)/abs", customHeaders: ["CF-Access-Client-Id": "id"])

        #expect(validated.status.supportsOpenID && validated.status.supportsLocalLogin)
        #expect(validated.status.authFormData?.authOpenIDButtonText == "Sign in with SSO")
        #expect(validated.configuration.customHeaders == ["CF-Access-Client-Id": "id"])
        let request = try #require(server.requests.first)
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "id")
    }

    @Test func notFoundIsNotAudiobookshelf() async throws {
        let server = StubServer { _ in .text("Not Found", status: 404) }
        await #expect(throws: ServerValidationError.notAudiobookshelf) {
            try await validator(server).validate(address: "https://\(server.host)")
        }
        #expect(ServerValidationError.notAudiobookshelf.localizedDescription.contains("Audiobookshelf server"))
    }

    @Test func otherJSONIsNotAudiobookshelf() async throws {
        let server = StubServer { _ in .json(#"{"hello":"world"}"#) }
        await #expect(throws: ServerValidationError.notAudiobookshelf) {
            try await validator(server).validate(address: "https://\(server.host)")
        }
    }

    @Test func uninitialisedServer() async throws {
        let server = stubServer(status: #"{"serverVersion":"2.26.0","isInit":false,"language":"en-us"}"#)
        await #expect(throws: ServerValidationError.serverNotInitialized) {
            try await validator(server).validate(address: "https://\(server.host)/abs")
        }
    }

    @Test(arguments: [
        ("2.25.9", "This server runs Audiobookshelf 2.25.9. Version 2.26.0 or newer is required."),
        ("1.0", "This server runs Audiobookshelf 1.0. Version 2.26.0 or newer is required."),
        ("banana", "Couldn't determine this server's Audiobookshelf version. Version 2.26.0 or newer is required."),
    ])
    func blocksOldOrUnparseableVersions(version: String, message: String) async throws {
        let server = stubServer(status: status(version: version))
        let error = await #expect(throws: ServerValidationError.self) {
            try await validator(server).validate(address: "https://\(server.host)/abs")
        }
        #expect(error == .unsupportedVersion(version))
        #expect(error?.localizedDescription == message)
    }

    @Test func blocksMissingVersion() async throws {
        let server = stubServer(status: status(version: nil))
        await #expect(throws: ServerValidationError.unsupportedVersion(nil)) {
            try await validator(server).validate(address: "https://\(server.host)/abs")
        }
    }

    @Test func invalidAddressAndReservedHeadersSendNothing() async throws {
        let server = stubServer()
        await #expect(throws: ServerValidationError.invalidAddress) {
            try await validator(server).validate(address: "ftp://\(server.host)")
        }
        await #expect(throws: ServerValidationError.reservedHeader(.reserved(name: "cookie"))) {
            try await validator(server).validate(address: server.host, customHeaders: ["cookie": "a=b"])
        }
        #expect(server.requests.isEmpty)
    }

    @Test func rejectsRedirectToAnotherHost() async throws {
        let other = stubServer()
        let server = StubServer { _ in .redirect(to: "https://\(other.host)/abs/status") }
        await #expect(throws: ServerValidationError.redirectedToOtherHost(other.host)) {
            try await validator(server).validate(address: "https://\(server.host)/abs")
        }
        #expect(other.requests.isEmpty)
    }

    @Test func rejectsRedirectChainThroughAnotherHost() async throws {
        let host = StubServer.uniqueHost()
        let other = StubServer { _ in .redirect(to: "https://\(host)/abs/status?back") }
        let server = StubServer(host: host) { request in
            request.url?.query() == "back" ? .json(statusLocal) : .redirect(to: "https://\(other.host)/abs/status")
        }
        await #expect(throws: ServerValidationError.redirectedToOtherHost(other.host)) {
            try await validator(server).validate(
                address: "https://\(server.host)/abs", customHeaders: ["CF-Access-Client-Secret": "secret"])
        }
        #expect(other.requests.isEmpty)
        #expect(server.requests.count == 1)
    }

    @Test func stopsAfterTooManyRedirects() async throws {
        let server = StubServer { request in .redirect(to: request.url?.absoluteString ?? "") }
        await #expect(throws: ServerValidationError.statusFailed(status: 302)) {
            try await validator(server).validate(address: "https://\(server.host)/abs")
        }
        #expect(server.requests.count == ServerValidator.maxStatusRedirects + 1)
    }

    @Test func refusesHTTPSToHTTPRedirect() async throws {
        let server = StubServer { request in
            guard request.url?.scheme == "https", let host = request.url?.host() else { return .json(statusLocal) }
            return .redirect(to: "http://\(host)/abs/status")
        }
        await #expect(throws: ServerValidationError.insecureRedirect) {
            try await validator(server).validate(address: "https://\(server.host)/abs")
        }
    }

    @Test func adoptsSameHostRedirectToAnotherPort() async throws {
        let server = StubServer { request in
            guard request.url?.port == nil, let host = request.url?.host() else { return .json(statusLocal) }
            return .redirect(to: "https://\(host):8443/abs/status", status: 308)
        }
        let validated = try await validator(server).validate(
            address: "https://\(server.host)/abs", customHeaders: ["CF-Access-Client-Secret": "secret"])
        #expect(validated.address.url.absoluteString == "https://\(server.host):8443/abs")
        #expect(validated.configuration.baseURL == validated.address.url)
        #expect(server.requests.map { $0.url?.port } == [nil, 8443])
        #expect(server.requests.allSatisfy { $0.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret" })
    }

    @Test(arguments: ["/abs/status/", "/abs/status?ready=1", "/abs/status?route=a+b&x=%20"])
    func followsRedirectToTheExactStatusURL(location: String) async throws {
        let server = StubServer { request in
            guard request.url?.absoluteString.hasSuffix("/abs/status") == true, let host = request.url?.host() else {
                return .json(statusLocal)
            }
            return .redirect(to: "https://\(host)\(location)")
        }
        let validated = try await validator(server).validate(address: "https://\(server.host)/abs")
        #expect(validated.address.url.absoluteString == "https://\(server.host)/abs")
        #expect(
            server.requests.map { $0.url?.absoluteString } == [
                "https://\(server.host)/abs/status", "https://\(server.host)\(location)",
            ])
    }

    @Test(arguments: [401, 403])
    func accessDeniedSuggestsCustomHeaders(status: Int) async throws {
        let server = StubServer { _ in .text("Forbidden", status: status) }
        let error = await #expect(throws: ServerValidationError.self) {
            try await validator(server).validate(address: "https://\(server.host)/abs")
        }
        #expect(error == .accessDenied(status: status))
        #expect(error?.localizedDescription.contains("custom headers") == true)
    }
}

@Suite struct ServerValidatorFallbackTests {
    @Test func triesHTTPSThenHTTPWithWarning() async throws {
        let server = StubServer { request in
            request.url?.scheme == "https" ? .failure(.cannotConnectToHost) : .json(statusLocal)
        }
        let validated = try await validator(server).validate(address: "\(server.host)/abs")

        #expect(
            server.requests.map { $0.url?.absoluteString } == [
                "https://\(server.host)/abs/status", "http://\(server.host)/abs/status",
            ])
        #expect(validated.fellBackToHTTP && validated.isInsecure)
        #expect(validated.address.url.absoluteString == "http://\(server.host)/abs")
        #expect(validated.configuration.baseURL == validated.address.url)
    }

    @Test func httpsSuccessDoesNotTryHTTP() async throws {
        let server = stubServer()
        let validated = try await validator(server).validate(address: "\(server.host)/abs")
        #expect(server.requests.map { $0.url?.scheme } == ["https"])
        #expect(!validated.fellBackToHTTP)
    }

    @Test func httpStatusResponseDoesNotFallBack() async throws {
        let server = StubServer { request in
            request.url?.scheme == "https" ? .text("Bad Gateway", status: 502) : .json(statusLocal)
        }
        await #expect(throws: ServerValidationError.statusFailed(status: 502)) {
            try await validator(server).validate(address: "\(server.host)/abs")
        }
        #expect(server.requests.count == 1)
    }

    @Test func keepsSameHostUpgradeToHTTPS() async throws {
        let server = StubServer { request in
            guard request.url?.scheme == "http", let host = request.url?.host() else { return .json(statusLocal) }
            return .redirect(to: "https://\(host)/abs/status", status: 301)
        }
        let validated = try await validator(server).validate(address: "http://\(server.host)/abs")
        #expect(validated.address.url.absoluteString == "https://\(server.host)/abs")
        #expect(!validated.isInsecure && !validated.fellBackToHTTP)
    }

    @Test func fallbackThenSameHostUpgradeIsNotFlaggedInsecure() async throws {
        let server = StubServer { request in
            guard let host = request.url?.host() else { return .failure(.badURL) }
            if request.url?.scheme == "http" { return .redirect(to: "https://\(host):8443/abs/status", status: 301) }
            return request.url?.port == 8443 ? .json(statusLocal) : .failure(.cannotConnectToHost)
        }
        let validated = try await validator(server).validate(address: "\(server.host)/abs")
        #expect(validated.address.url.absoluteString == "https://\(server.host):8443/abs")
        #expect(!validated.fellBackToHTTP && !validated.isInsecure)
    }

    @Test func fallsBackAfterTimeout() async throws {
        let server = StubServer { request in
            request.url?.scheme == "https" ? .failure(.timedOut) : .json(statusLocal)
        }
        let validated = try await validator(server).validate(address: "\(server.host)/abs")
        #expect(server.requests.map { $0.url?.scheme } == ["https", "http"])
        #expect(validated.fellBackToHTTP)
    }

    @Test func failureAfterARedirectDoesNotFallBack() async throws {
        let server = StubServer { request in
            guard request.url?.scheme == "https", let host = request.url?.host() else { return .json(statusLocal) }
            return request.url?.port == 8443 ? .failure(.timedOut) : .redirect(to: "https://\(host):8443/abs/status")
        }
        await #expect(throws: ServerValidationError.timedOut) {
            try await validator(server).validate(address: "\(server.host)/abs")
        }
        #expect(server.requests.map { $0.url?.scheme } == ["https", "https"])
    }

    @Test func fallsBackAfterSecureConnectionFailure() async throws {
        let server = StubServer { request in
            request.url?.scheme == "https" ? .failure(.secureConnectionFailed) : .json(statusLocal)
        }
        let validated = try await validator(server).validate(address: "\(server.host)/abs")
        #expect(validated.fellBackToHTTP)
    }

    @Test func bothCandidatesFailing() async throws {
        let server = StubServer { request in
            .failure(request.url?.scheme == "https" ? .cannotConnectToHost : .cannotFindHost)
        }
        await #expect(throws: ServerValidationError.cannotConnect(.cannotFindHost)) {
            try await validator(server).validate(address: "\(server.host)/abs")
        }
        #expect(server.requests.map { $0.url?.scheme } == ["https", "http"])
    }

    @Test(arguments: Array(ServerValidator.certificateErrors))
    func certificateErrorsDoNotFallBack(code: URLError.Code) async throws {
        let server = StubServer { request in
            request.url?.scheme == "https" ? .failure(code) : .json(statusLocal)
        }
        await #expect(throws: ServerValidationError.untrustedCertificate) {
            try await validator(server).validate(address: "\(server.host)/abs")
        }
        #expect(server.requests.count == 1)
    }

    @Test func customHeadersAreNeverSentOverInferredHTTP() async throws {
        let server = StubServer { request in
            request.url?.scheme == "https" ? .failure(.cannotConnectToHost) : .json(statusLocal)
        }
        let headers = ["CF-Access-Client-Secret": "secret"]
        let httpAddress = try #require(ServerAddress("http://\(server.host)/abs"))
        await #expect(throws: ServerValidationError.httpsUnavailable(httpAddress)) {
            try await validator(server).validate(address: "\(server.host)/abs", customHeaders: headers)
        }
        #expect(server.requests.map { $0.url?.scheme } == ["https"])

        // After the user agrees, the explicit http address sends the headers.
        let validated = try await validator(server).validate(address: httpAddress.description, customHeaders: headers)
        #expect(validated.isInsecure && !validated.fellBackToHTTP)
        let request = try #require(server.requests.last)
        #expect(request.url?.scheme == "http")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")
    }

    @Test func explicitHTTPSDoesNotFallBack() async throws {
        let server = StubServer { request in
            request.url?.scheme == "https" ? .failure(.cannotConnectToHost) : .json(statusLocal)
        }
        await #expect(throws: ServerValidationError.cannotConnect(.cannotConnectToHost)) {
            try await validator(server).validate(address: "https://\(server.host)/abs")
        }
        #expect(server.requests.count == 1)
    }
}

@Suite struct ServerValidatorLoginTests {
    @Test func loginMapsTokensAndFeatures() async throws {
        let server = stubServer(login: .json(authResponseJSON(version: "2.37.2")))
        let validator = validator(server)
        let validated = try await validator.validate(
            address: "https://\(server.host)/abs", customHeaders: ["X-Proxy": "proxy"])

        let result = try await validator.login(to: validated, username: "david", password: "pw")

        #expect(result.tokens == ABSAPI.AuthTokens(accessToken: "access-new", refreshToken: "refresh-new"))
        #expect(result.response.user.username == "david")
        #expect(result.features.version == ServerVersion(2, 37, 2))
        let request = try #require(server.requests(path: "/abs/login").first)
        #expect(request.value(forHTTPHeaderField: "x-return-tokens") == "true")
        #expect(request.value(forHTTPHeaderField: "X-Proxy") == "proxy")
    }

    @Test func wrongPassword() async throws {
        let server = stubServer(login: .text("Unauthorized", status: 401))
        let validator = validator(server)
        let validated = try await validator.validate(address: "https://\(server.host)/abs")

        let error = await #expect(throws: ServerValidationError.self) {
            try await validator.login(to: validated, username: "david", password: "nope")
        }
        #expect(error == .invalidCredentials)
        #expect(error?.localizedDescription == "Incorrect username or password.")
    }

    @Test func rateLimited() async throws {
        let server = stubServer(login: .json(#"{"error":"Too many authentication requests"}"#, status: 429))
        let validator = validator(server)
        let validated = try await validator.validate(address: "https://\(server.host)/abs")
        await #expect(throws: ServerValidationError.tooManyAttempts) {
            try await validator.login(to: validated, username: "david", password: "pw")
        }
    }

    @Test func loginRechecksVersionAndLogsOut() async throws {
        let server = stubServer(login: .json(authResponseJSON(version: "2.25.0")))
        let validator = validator(server)
        let validated = try await validator.validate(address: "https://\(server.host)/abs")
        await #expect(throws: ServerValidationError.unsupportedVersion("2.25.0")) {
            try await validator.login(to: validated, username: "david", password: "pw")
        }
        let logout = try #require(server.requests(path: "/abs/logout").first)
        #expect(logout.value(forHTTPHeaderField: "x-refresh-token") == "refresh-new")
    }

    @Test func loginWithoutAccessTokenFailsAndLogsOut() async throws {
        let body =
            #"{"user":{"id":"usr-1","username":"david","refreshToken":"refresh-new"},"#
            + #""serverSettings":{"version":"2.26.0"}}"#
        let server = stubServer(login: .json(body))
        let validator = validator(server)
        let validated = try await validator.validate(address: "https://\(server.host)/abs")
        await #expect(throws: ServerValidationError.missingTokens) {
            try await validator.login(to: validated, username: "david", password: "pw")
        }
        let logout = try #require(server.requests(path: "/abs/logout").first)
        #expect(logout.value(forHTTPHeaderField: "x-refresh-token") == "refresh-new")
    }

    @Test func undecodableLoginLogsOut() async throws {
        let body =
            #"{"user":{"id":"usr-1","username":42,"accessToken":"access-new","refreshToken":"refresh-new"},"#
            + #""serverSettings":{"version":"2.26.0"}}"#
        let server = stubServer(login: .json(body))
        let validator = validator(server)
        let validated = try await validator.validate(address: "https://\(server.host)/abs")
        let error = await #expect(throws: ServerValidationError.self) {
            try await validator.login(to: validated, username: "david", password: "pw")
        }
        #expect(error == .unexpected(.decoding("AuthResponse")))
        let logout = try #require(server.requests(path: "/abs/logout").first)
        #expect(logout.value(forHTTPHeaderField: "x-refresh-token") == "refresh-new")
    }

    @Test func loginWithoutTokensFails() async throws {
        let server = stubServer(login: .json(authResponseJSON(tokens: false)))
        let validator = validator(server)
        let validated = try await validator.validate(address: "https://\(server.host)/abs")
        await #expect(throws: ServerValidationError.missingTokens) {
            try await validator.login(to: validated, username: "david", password: "pw")
        }
        #expect(server.requests(path: "/abs/logout").isEmpty)
    }

    @Test func loginDoesNotFollowCrossOriginRedirect() async throws {
        let other = stubServer()
        let server = stubServer(login: .redirect(to: "https://\(other.host)/abs/login", status: 307))
        let validator = validator(server)
        let validated = try await validator.validate(address: "https://\(server.host)/abs")
        await #expect(throws: ServerValidationError.loginRedirected) {
            try await validator.login(to: validated, username: "david", password: "pw")
        }
        #expect(other.requests.isEmpty)
    }

    @Test func loginDoesNotFollowSameOriginRedirect() async throws {
        let server = StubServer { request in
            switch request.url?.path() {
            case "/abs/status": .json(statusLocal)
            case "/abs/login": .redirect(to: "https://\(request.url?.host() ?? "")/abs/login/", status: 308)
            default: .json(authResponseJSON())
            }
        }
        let validator = validator(server)
        let validated = try await validator.validate(address: "https://\(server.host)/abs")
        let error = await #expect(throws: ServerValidationError.self) {
            try await validator.login(to: validated, username: "david", password: "pw")
        }
        #expect(error == .loginRedirected)
        #expect(server.requests.filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test func authorizeRechecksVersion() async throws {
        let server = StubServer { _ in .json(authResponseJSON(version: "2.26.1", tokens: false)) }
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: server.baseURL),
            tokenProvider: InMemoryTokenProvider(), sessionConfiguration: server.sessionConfiguration())
        let result = try await validator(server).authorize(with: client)
        #expect(result.features.version == ServerVersion(2, 26, 1))

        let downgraded = StubServer { _ in .json(authResponseJSON(version: "2.20.0", tokens: false)) }
        let downgradedClient = APIClient(
            configuration: try APIClientConfiguration(baseURL: downgraded.baseURL),
            tokenProvider: InMemoryTokenProvider(), sessionConfiguration: downgraded.sessionConfiguration())
        await #expect(throws: ServerValidationError.unsupportedVersion("2.20.0")) {
            try await validator(downgraded).authorize(with: downgradedClient)
        }
    }

    @Test func authorizeRejectedRefreshNeedsSignIn() async throws {
        let server = StubServer { _ in .text("Unauthorized", status: 401) }
        let tokens = InMemoryTokenProvider()
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: server.baseURL),
            tokenProvider: tokens, sessionConfiguration: server.sessionConfiguration())
        await #expect(throws: ServerValidationError.sessionExpired) {
            try await validator(server).authorize(with: client)
        }
        #expect(tokens.expiredCount == 1)
    }

    /// A proxy's 403, on the request or on the refresh, keeps the session.
    @Test(arguments: ["/abs/api/authorize", "/abs/auth/refresh"])
    func authorizeProxyForbiddenIsAccessDenied(forbiddenPath: String) async throws {
        let server = StubServer { request in
            request.url?.path() == forbiddenPath
                ? .text("Forbidden", status: 403) : .text("Unauthorized", status: 401)
        }
        let tokens = InMemoryTokenProvider()
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: server.baseURL),
            tokenProvider: tokens, sessionConfiguration: server.sessionConfiguration())
        await #expect(throws: ServerValidationError.accessDenied(status: 403)) {
            try await validator(server).authorize(with: client)
        }
        #expect(tokens.expiredCount == 0 && tokens.current != nil)
    }

    @Test func authorizeRefreshRedirectedToAnotherHost() async throws {
        let other = StubServer { _ in .json(#"{"user":{"accessToken":"a","refreshToken":"r"}}"#) }
        let server = StubServer { request in
            request.url?.path() == "/abs/auth/refresh"
                ? .redirect(to: "https://\(other.host)/abs/auth/refresh", status: 307)
                : .text("Unauthorized", status: 401)
        }
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: server.baseURL),
            tokenProvider: InMemoryTokenProvider(), sessionConfiguration: server.sessionConfiguration())
        await #expect(throws: ServerValidationError.loginRedirected) {
            try await validator(server).authorize(with: client)
        }
        #expect(other.requests.isEmpty)
    }

    @Test(arguments: [307, 302])
    func authorizeDoesNotTrustARedirect(status: Int) async throws {
        let other = StubServer { _ in .json(authResponseJSON(tokens: false)) }
        let server = StubServer { _ in .redirect(to: "https://\(other.host)/abs/api/authorize", status: status) }
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: server.baseURL),
            tokenProvider: InMemoryTokenProvider(), sessionConfiguration: server.sessionConfiguration())
        await #expect(throws: ServerValidationError.loginRedirected) {
            try await validator(server).authorize(with: client)
        }
        #expect(other.requests.isEmpty)
    }

    @Test func authorizeWithoutTokensNeedsSignIn() async throws {
        let server = StubServer { _ in .json(authResponseJSON(tokens: false)) }
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: server.baseURL),
            tokenProvider: InMemoryTokenProvider(nil), sessionConfiguration: server.sessionConfiguration())
        await #expect(throws: ServerValidationError.sessionExpired) {
            try await validator(server).authorize(with: client)
        }
        #expect(server.requests.isEmpty)
    }

    @Test func authorizeNetworkFailure() async throws {
        let server = StubServer { _ in .failure(.notConnectedToInternet) }
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: server.baseURL),
            tokenProvider: InMemoryTokenProvider(), sessionConfiguration: server.sessionConfiguration())
        await #expect(throws: ServerValidationError.cannotConnect(.notConnectedToInternet)) {
            try await validator(server).authorize(with: client)
        }
    }
}

@Suite struct ServerValidationErrorTests {
    @Test func everyCaseHasAFriendlyMessage() throws {
        let address = try #require(ServerAddress("http://abs.example"))
        let cases: [ServerValidationError] = [
            .invalidAddress, .reservedHeader(.reserved(name: "Cookie")), .cannotConnect(.cannotFindHost), .timedOut,
            .untrustedCertificate, .httpsUnavailable(address), .notAudiobookshelf, .accessDenied(status: 401),
            .statusFailed(status: 500), .redirectedToOtherHost("evil.example"), .insecureRedirect,
            .serverNotInitialized, .unsupportedVersion("2.25.0"), .unsupportedVersion(nil), .invalidCredentials,
            .tooManyAttempts, .loginRedirected, .missingTokens, .sessionExpired,
            .unexpected(.http(status: 500, message: "<html>stack trace</html>")),
        ]
        for error in cases {
            let message = try #require(error.errorDescription)
            #expect(!message.isEmpty && !message.contains("ServerValidationError") && !message.contains("APIError"))
        }
        #expect(Set(cases.compactMap(\.errorDescription)).count == cases.count - 1)  // cannotConnect == timedOut
        #expect(
            ServerValidationError.httpsUnavailable(address).errorDescription?.contains("http://abs.example") == true)
    }

    @Test func unexpectedErrorsHideServerText() {
        let error = ServerValidationError.unexpected(.http(status: 500, message: "<html>stack trace</html>"))
        #expect(error.errorDescription == "Something went wrong while talking to the server. Try again.")
        #expect(error.diagnosticDescription == "unexpected(http(status: 500))")
        let decoding = ServerValidationError.unexpected(.decoding("dataCorrupted: <html>stack trace</html>"))
        #expect(decoding.errorDescription == error.errorDescription)
        #expect(decoding.diagnosticDescription == "unexpected(decoding failed)")
    }
}
