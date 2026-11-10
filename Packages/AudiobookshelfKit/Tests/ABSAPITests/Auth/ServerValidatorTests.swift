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

    @Test func loginRechecksVersion() async throws {
        let server = stubServer(login: .json(authResponseJSON(version: "2.25.0")))
        let validator = validator(server)
        let validated = try await validator.validate(address: "https://\(server.host)/abs")
        await #expect(throws: ServerValidationError.unsupportedVersion("2.25.0")) {
            try await validator.login(to: validated, username: "david", password: "pw")
        }
    }

    @Test func loginWithoutRefreshTokenFails() async throws {
        let server = stubServer(login: .json(authResponseJSON(tokens: false)))
        let validator = validator(server)
        let validated = try await validator.validate(address: "https://\(server.host)/abs")
        await #expect(throws: ServerValidationError.missingTokens) {
            try await validator.login(to: validated, username: "david", password: "pw")
        }
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
}
