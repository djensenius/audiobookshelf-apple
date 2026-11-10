import Foundation

/// The HTTP client for one Audiobookshelf server connection.
///
/// Every request carries the connection's custom headers. Authenticated requests carry the
/// access token; on a 401 the client refreshes the tokens once with `POST /auth/refresh`
/// (concurrent 401s share a single refresh), persists them through the ``TokenProvider``, and
/// retries the request once. If the server rejects the refresh token, the provider ends the
/// session and ``APIError/sessionExpired`` is thrown. If the user signs out or in again while a
/// refresh is in flight, its result is discarded and waiting requests throw `CancellationError`.
/// Redirects follow ``RedirectPolicy``; a 401 from a hop that was stripped of credentials is
/// thrown as ``APIError/unauthorized(message:)`` and never refreshes or ends the session. The
/// refresh itself only follows same-origin redirects, so tokens only come from the server.
public actor APIClient {
    public private(set) var configuration: APIClientConfiguration
    private let tokenProvider: any TokenProvider
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// In-flight refreshes keyed by the token pair being refreshed, so a request only joins a
    /// refresh of its own pair (not one left over from a previous sign-in).
    private var refreshFlights: [AuthTokens: RefreshFlight] = [:]
    private var nextFlightID = 0
    /// Recent successful refreshes as (rejected pair, refreshed pair, generation). They tell a
    /// stale token read apart from a session that needs refreshing, and whether the current pair
    /// descends from a rejected one. A refresh that returns the same pair is recorded as `(A, A)`.
    /// Edges can be appended out of order (a slow provider may return after a later refresh).
    private var completedRefreshes: [CompletedRefresh] = []
    /// Bumped each time a refresh completes. A request only reuses refreshes that completed
    /// after it was sent, so an old refresh never stands in for a new 401.
    private var refreshGeneration = 0
    private static let completedRefreshLimit = 8

    private struct CompletedRefresh {
        let from: AuthTokens
        let to: AuthTokens
        let generation: Int
    }

    private struct RefreshFlight {
        let id: Int
        let task: Task<Void, any Error>
    }

    /// Tokens to retry with, and whether a refresh of the rejected pair produced them (rather
    /// than a different session that replaced it, which hasn't been refreshed yet).
    private struct RefreshOutcome {
        let tokens: AuthTokens
        let didRefresh: Bool
    }

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
        let followsRedirects = endpoint.followsRedirects

        guard endpoint.requiresAuthentication else {
            let reply = try await perform(request, followsRedirects: followsRedirects)
            return try handle(reply.data, reply.http, for: endpoint)
        }

        // The refresh generation before `tokens` was read. A 401 for `tokens` reuses any refresh
        // completed after that, including one that finished between the read and the send.
        var tokensGeneration = refreshGeneration
        guard var tokens = await tokenProvider.tokens() else { throw APIError.notAuthenticated }
        // The pair a refresh produced for this request. That pair being rejected ends the
        // session; any other pair (for example from a new sign-in) gets its own refresh first.
        var refreshedPair: AuthTokens?
        // Bounds the sends if the tokens keep changing: the original, the retry after a refresh,
        // and two more for a session that replaced the first one and needs its own refresh.
        var sendsLeft = 4
        while true {
            sendsLeft -= 1
            let reply = try await perform(authorized(request, tokens.accessToken), followsRedirects: followsRedirects)
            // A 401 from a hop that never received the token says nothing about the token.
            guard reply.http.statusCode == 401, !reply.credentialsStripped else {
                return try handle(reply.data, reply.http, for: endpoint)
            }
            let next: AuthTokens
            let nextGeneration = refreshGeneration
            if tokens == refreshedPair {
                // Always handled, whatever the send budget: the refreshed pair is rejected, so the
                // session is over unless a different one replaced it in the meantime.
                guard let current = await expireSession(rejected: tokens) else { throw APIError.sessionExpired }
                // A pair another request refreshed from the rejected one is still this chain's
                // refreshed session, so its rejection expires too instead of refreshing again.
                if outcome(current, after: tokens, since: tokensGeneration).didRefresh { refreshedPair = current }
                next = current
            } else {
                guard sendsLeft > 0 else { return try handle(reply.data, reply.http, for: endpoint) }
                let outcome = try await refreshedTokens(replacing: tokens, readAt: tokensGeneration)
                if outcome.didRefresh { refreshedPair = outcome.tokens }
                next = outcome.tokens
            }
            guard sendsLeft > 0 else { return try handle(reply.data, reply.http, for: endpoint) }
            tokens = next
            tokensGeneration = nextGeneration
            try Task.checkCancellation()
        }
    }

    // MARK: - Token refresh

    /// Returns the tokens to retry with after `rejected` got a 401, where `rejected` was read at
    /// refresh generation `sent`: joins a refresh of the same pair if one is running, reuses one
    /// that completed after the read, or starts one. The result is always the provider's current
    /// pair, so a sign-out or new sign-in since the refresh wins.
    private func refreshedTokens(replacing rejected: AuthTokens, readAt sent: Int) async throws -> RefreshOutcome {
        var hasRereadStaleTokens = false
        while true {
            if let flight = refreshFlights[rejected] {
                try await flight.task.value
                return try await currentOutcome(after: rejected, since: sent)
            }
            guard let current = await tokenProvider.tokens() else { throw APIError.sessionExpired }
            // A refresh may have started during the read above.
            if refreshFlights[rejected] != nil { continue }
            // Either a completed refresh already produced `current`, or it is a different session.
            let result = outcome(current, after: rejected, since: sent)
            if result.didRefresh || current != rejected { return result }
            // A refresh of `rejected` already finished, so the read predates it; read once more.
            if !hasRereadStaleTokens, completedRefresh(of: rejected, since: sent) {
                hasRereadStaleTokens = true
                continue
            }
            if let flight = refreshFlights[current] {
                try await flight.task.value
                return try await currentOutcome(after: rejected, since: sent)
            }

            nextFlightID += 1
            let id = nextFlightID
            let task = Task {
                // The flight unregisters itself before it finishes, so no request can join it
                // once it has completed (for example while this request reads the new tokens).
                // Only this flight's entry is removed, never a newer flight for the same pair.
                defer { if refreshFlights[current]?.id == id { refreshFlights[current] = nil } }
                try await refresh(current)
            }
            refreshFlights[current] = RefreshFlight(id: id, task: task)
            try await task.value
            return try await currentOutcome(after: rejected, since: sent)
        }
    }

    /// The provider's current pair after a refresh of `rejected` finished.
    private func currentOutcome(after rejected: AuthTokens, since sent: Int) async throws -> RefreshOutcome {
        guard let current = await tokenProvider.tokens() else { throw APIError.sessionExpired }
        return outcome(current, after: rejected, since: sent)
    }

    /// `current` counts as refreshed only if it descends from `rejected` through one or more
    /// refreshes completed after generation `sent` (including one that returned the same pair);
    /// otherwise it belongs to a different session, or the session needs a new refresh.
    private func outcome(_ current: AuthTokens, after rejected: AuthTokens, since sent: Int) -> RefreshOutcome {
        var next: [AuthTokens: [AuthTokens]] = [:]
        for refresh in completedRefreshes where refresh.generation > sent {
            next[refresh.from, default: []].append(refresh.to)
        }
        // Walks the edges from `rejected` to a fixed point, so their order doesn't matter.
        var descendants: Set<AuthTokens> = []
        var pending = next[rejected] ?? []
        while let pair = pending.popLast() {
            if descendants.insert(pair).inserted { pending += next[pair] ?? [] }
        }
        return RefreshOutcome(tokens: current, didRefresh: descendants.contains(current))
    }

    private func completedRefresh(of rejected: AuthTokens, since sent: Int) -> Bool {
        completedRefreshes.contains { $0.from == rejected && $0.generation > sent }
    }

    private func refresh(_ tokens: AuthTokens) async throws {
        var request = try makeRequest(
            for: Endpoint<EmptyResponse>(.post, "/auth/refresh", requiresAuthentication: false)
        )
        request.setValue(tokens.refreshToken, forHTTPHeaderField: "x-refresh-token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Only same-origin redirects are followed: a hop off the origin never receives the refresh
        // token, so anything it returns (including tokens) must not be trusted. Such a redirect is
        // declined and surfaces as `.redirectRefused`.
        let reply = try await perform(request, followsRedirects: true, staysOnOrigin: true)
        guard !reply.credentialsStripped else { throw APIError.invalidResponse }
        let data = reply.data
        switch reply.http.statusCode {
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
            // A sign-out or new sign-in during the refresh wins; this request belonged to the
            // session that ended, so it is cancelled rather than retried.
            guard await tokenProvider.replaceTokens(expected: tokens, with: refreshed) else {
                throw CancellationError()
            }
            // Recorded before the flight's task finishes, so no request can miss both the
            // flight and its result.
            refreshGeneration += 1
            completedRefreshes.append(CompletedRefresh(from: tokens, to: refreshed, generation: refreshGeneration))
            if completedRefreshes.count > Self.completedRefreshLimit { completedRefreshes.removeFirst() }
            return
        case 401:
            // The server only answers 401 for a bad refresh token; a 403 here comes from a proxy
            // or firewall and must not sign the user out.
            // A different session replaced this one; requests retry with it via `currentOutcome`.
            guard await expireSession(rejected: tokens) != nil else { throw APIError.sessionExpired }
        default:
            throw Self.error(status: reply.http.statusCode, data: data)
        }
    }

    /// Ends the session if `rejected` is still current. Otherwise the stored tokens changed
    /// since it was used (for example the user signed in again) and the newer tokens are
    /// returned; returns `nil` when the session is over.
    private func expireSession(rejected: AuthTokens) async -> AuthTokens? {
        if await tokenProvider.expireSession(ifCurrent: rejected) { return nil }
        guard let current = await tokenProvider.tokens(), current != rejected else { return nil }
        return current
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

    private struct Reply {
        let data: Data
        let http: HTTPURLResponse
        /// Whether a redirect hop was stripped of credentials, so the response came from a
        /// request without `Authorization`, custom headers or cookies.
        let credentialsStripped: Bool
    }

    /// - Parameter staysOnOrigin: Declines any redirect that would leave the origin (and so be
    ///   stripped of credentials) instead of following it without them.
    private func perform(
        _ request: URLRequest, followsRedirects: Bool, staysOnOrigin: Bool = false
    ) async throws -> Reply {
        let chain = followsRedirects ? RedirectChainDelegate(staysOnOrigin: staysOnOrigin) : nil
        let delegate: any URLSessionTaskDelegate = chain ?? RedirectSuppressingDelegate()
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
        return Reply(data: data, http: http, credentialsStripped: chain?.credentialsStripped ?? false)
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
    /// Existing `%XX` escapes in `path` (from ``pathSegment(_:)``) are kept, not encoded again.
    static func url(base: URL, path: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = basePath + percentEncodedPath(path.hasPrefix("/") ? path : "/" + path)
        if !query.isEmpty {
            components.queryItems = query
            // URLComponents leaves "+" alone, but servers decode it as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw APIError.invalidURL }
        return url
    }

    /// Percent-encodes characters that aren't allowed in a path, keeping valid `%XX` escapes.
    static func percentEncodedPath(_ path: String) -> String {
        func encode(_ text: Substring) -> String {
            text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        }
        let parts = path.split(separator: "%", omittingEmptySubsequences: false)
        var result = encode(parts[0])
        for part in parts.dropFirst() {
            let escape = part.prefix(2)
            if escape.count == 2, escape.allSatisfy({ $0.isASCII && $0.isHexDigit }) {
                result += "%" + escape + encode(part.dropFirst(2))
            } else {
                result += "%25" + encode(part)
            }
        }
        return result
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
