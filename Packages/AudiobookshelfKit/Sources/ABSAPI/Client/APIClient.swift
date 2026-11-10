import Foundation

/// The HTTP client for one Audiobookshelf server connection.
///
/// Every request carries the connection's custom headers. Authenticated requests carry the
/// access token; on a 401 the client refreshes the tokens once with `POST /auth/refresh`
/// (concurrent 401s share a single refresh), persists them through the ``TokenProvider``, and
/// retries the request once. If the server rejects the refresh token, the provider is told the
/// session expired and ``APIError/sessionExpired`` is thrown. Redirects follow ``RedirectPolicy``.
public actor APIClient {
    public private(set) var configuration: APIClientConfiguration
    private let tokenProvider: any TokenProvider
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var refreshTask: Task<AuthTokens, any Error>?
    /// The last token pair reported to ``TokenProvider/sessionExpired()``, so concurrent
    /// rejections of the same pair report it once.
    private var expiredTokens: AuthTokens?

    /// - Parameter sessionConfiguration: Tests pass a configuration with stub protocol classes.
    ///   It is copied, and the copy always gets its own new cookie jar, so reusing a
    ///   configuration never shares cookies between connections.
    public init(
        configuration: APIClientConfiguration,
        tokenProvider: any TokenProvider,
        sessionConfiguration: URLSessionConfiguration = .absConnection()
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        let sessionConfiguration = sessionConfiguration.copy() as? URLSessionConfiguration ?? .absConnection()
        sessionConfiguration.httpCookieStorage = URLSessionConfiguration.ephemeral.httpCookieStorage
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeout
        session = URLSession(
            configuration: sessionConfiguration, delegate: RedirectPolicyDelegate(), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// This connection's cookie jar, shared by every request the client sends.
    nonisolated var cookieStorage: HTTPCookieStorage? {
        session.configuration.httpCookieStorage
    }

    /// Replaces the connection's custom headers.
    /// - Throws: ``CustomHeaderError`` if a header is reserved (`Authorization` or `Cookie`).
    public func setCustomHeaders(_ headers: [String: String]) throws(CustomHeaderError) {
        try configuration.setCustomHeaders(headers)
    }

    /// Sends `endpoint` and decodes its response.
    public func send<Response>(_ endpoint: Endpoint<Response>) async throws -> Response {
        try await response(for: endpoint).value
    }

    /// Sends `endpoint` and returns the decoded value with its HTTP response.
    public func response<Response>(for endpoint: Endpoint<Response>) async throws -> APIResponse<Response> {
        let request = try makeRequest(for: endpoint)
        let delegate = endpoint.followsRedirects ? nil : RedirectSuppressingDelegate()

        guard endpoint.requiresAuthentication else {
            let (data, http) = try await perform(request, delegate: delegate)
            return try handle(data, http, for: endpoint)
        }

        guard var tokens = await tokenProvider.tokens() else { throw APIError.notAuthenticated }
        var hasRefreshed = false
        // At most three sends: the original, the retry after a refresh, and one more if the
        // tokens changed again (for example a new sign-in) while the retry was in flight.
        for _ in 0..<3 {
            let (data, http) = try await perform(authorized(request, tokens.accessToken), delegate: delegate)
            guard http.statusCode == 401 else { return try handle(data, http, for: endpoint) }
            if hasRefreshed {
                guard let current = await expireSession(rejected: tokens) else { throw APIError.sessionExpired }
                tokens = current
            } else {
                tokens = try await refreshedTokens(replacing: tokens)
                hasRefreshed = true
            }
            try Task.checkCancellation()
        }
        throw APIError.sessionExpired
    }

    // MARK: - Token refresh

    /// Returns tokens newer than `rejected`, starting a refresh only if none is running and no
    /// other request has already refreshed.
    private func refreshedTokens(replacing rejected: AuthTokens) async throws -> AuthTokens {
        if let refreshTask { return try await refreshTask.value }
        let current = await tokenProvider.tokens()
        // Re-check after the suspension above; another request may have started a refresh.
        if let refreshTask { return try await refreshTask.value }
        guard let current else { throw APIError.sessionExpired }
        if current.accessToken != rejected.accessToken { return current }

        let task = Task { try await refresh(current) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func refresh(_ tokens: AuthTokens) async throws -> AuthTokens {
        var request = try makeRequest(
            for: Endpoint<EmptyResponse>(.post, "/auth/refresh", requiresAuthentication: false)
        )
        request.setValue(tokens.refreshToken, forHTTPHeaderField: "x-refresh-token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, http) = try await perform(request, delegate: nil)
        switch http.statusCode {
        case 200..<300:
            let body: RefreshResponse
            do {
                body = try decoder.decode(RefreshResponse.self, from: data)
            } catch {
                throw APIError.decoding(String(describing: error))
            }
            guard !body.user.accessToken.isEmpty else { throw APIError.decoding("Missing accessToken") }
            let refreshed = AuthTokens(
                accessToken: body.user.accessToken,
                refreshToken: body.user.refreshToken ?? tokens.refreshToken
            )
            await tokenProvider.update(refreshed)
            return refreshed
        case 401:
            // The server only answers 401 for a bad refresh token; a 403 here comes from a proxy
            // or firewall and must not sign the user out.
            guard let current = await expireSession(rejected: tokens) else { throw APIError.sessionExpired }
            return current
        default:
            throw Self.error(status: http.statusCode, data: data)
        }
    }

    /// Reports `rejected` as expired unless the stored tokens have changed since it was used
    /// (for example after the user signed in again). Returns the newer tokens in that case, or
    /// `nil` when the session is over.
    private func expireSession(rejected: AuthTokens) async -> AuthTokens? {
        let current = await tokenProvider.tokens()
        guard current == rejected else { return current }
        if expiredTokens != rejected {
            expiredTokens = rejected
            await tokenProvider.sessionExpired()
        }
        return nil
    }

    private struct RefreshResponse: Decodable {
        struct User: Decodable {
            let accessToken: String
            let refreshToken: String?
        }
        let user: User
    }

    // MARK: - Requests

    private func makeRequest<Response>(for endpoint: Endpoint<Response>) throws -> URLRequest {
        var request = URLRequest(
            url: try Self.url(base: configuration.baseURL, path: endpoint.path, query: endpoint.query)
        )
        request.httpMethod = endpoint.method.rawValue
        request.timeoutInterval = endpoint.timeout ?? configuration.timeout
        for (name, value) in configuration.customHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body = endpoint.body {
            do {
                request.httpBody = try encoder.encode(body)
            } catch {
                throw APIError.encoding(String(describing: error))
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in endpoint.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func authorized(_ request: URLRequest, _ accessToken: String) -> URLRequest {
        var request = request
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func perform(
        _ request: URLRequest,
        delegate: (any URLSessionTaskDelegate)?
    ) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: delegate)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw APIError.timedOut
            default: throw APIError.network(error.code)
            }
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return (data, http)
    }

    private func handle<Response>(
        _ data: Data,
        _ http: HTTPURLResponse,
        for endpoint: Endpoint<Response>
    ) throws -> APIResponse<Response> {
        let status = http.statusCode
        let isSuccess = (200..<300).contains(status) || (!endpoint.followsRedirects && (300..<400).contains(status))
        guard isSuccess else { throw Self.error(status: status, data: data) }

        if let empty = EmptyResponse() as? Response {
            return APIResponse(value: empty, httpResponse: http)
        }
        if let raw = data as? Response {
            return APIResponse(value: raw, httpResponse: http)
        }
        do {
            return APIResponse(value: try decoder.decode(Response.self, from: data), httpResponse: http)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    // MARK: - Helpers

    /// Appends `path` to the base URL's path, so a server hosted under a subpath keeps it.
    static func url(base: URL, path: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + (path.hasPrefix("/") ? path : "/" + path)
        if !query.isEmpty {
            components.queryItems = query
            // URLComponents leaves "+" alone, but servers decode it as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw APIError.invalidURL }
        return url
    }

    static func error(status: Int, data: Data) -> APIError {
        let message = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = message?.isEmpty == false ? message : nil
        switch status {
        case 401: return .unauthorized(message: text)
        case 403: return .forbidden(message: text)
        case 404: return .notFound
        case 300..<400: return .redirectRefused(status: status)
        default: return .http(status: status, message: text)
        }
    }
}
