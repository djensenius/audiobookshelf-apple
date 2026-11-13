import Foundation

/// The HTTP client for one Audiobookshelf server connection.
///
/// Every request carries the connection's custom headers. Authenticated requests carry the
/// access token; on a 401 the client refreshes the tokens once with `POST /auth/refresh`
/// (concurrent 401s share a single refresh, and clients sharing a provider share it through
/// ``TokenProvider/refreshTokens(_:using:)``), persists them through the ``TokenProvider``, and
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
    /// Successful refreshes as (rejected pair, refreshed pair, generation). They tell a
    /// stale token read apart from a session that needs refreshing, and whether the current pair
    /// descends from a rejected one. A refresh that returns the same pair is recorded as `(A, A)`.
    /// Edges can be appended out of order (a slow provider may return after a later refresh).
    private var completedRefreshes: [CompletedRefresh] = []
    /// Bumped each time a refresh completes. A request only reuses refreshes that completed
    /// after it was sent, so an old refresh never stands in for a new 401.
    private var refreshGeneration = 0
    /// How many in-flight requests read their tokens at each generation. A refresh is only
    /// consulted by requests that read before it completed, so `completedRefreshes` keeps every
    /// refresh newer than the oldest of these and drops the rest (no fixed limit that could drop
    /// a pair a slow request still needs to trace).
    private var requestGenerations: [Int: Int] = [:]
    /// Test hook: called whenever a request starts waiting for a refresh another request started.
    private var refreshJoinObserver: (@Sendable () -> Void)?
    /// The clock for access token expiry; tests replace it with ``setNow(_:)``.
    private var now: @Sendable () -> Date = { Date() }
    /// What token access knows about each pair a refresh produced or rejected (see
    /// ``PairState``). Written only for those pairs, and pruned only by ``pruneCompletedRefreshes()``.
    private var pairStates: [AuthTokens: PairState] = [:]
    private var nextSwapID = 0
    /// Server expirations whose provider call hasn't returned. The provider may clear the tokens
    /// before it returns, so a caller that finds them gone waits for these before deciding
    /// whether the server or a local sign-out ended the session.
    private var pendingExpiries: [Int: Task<Bool, Never>] = [:]
    private var nextExpiryID = 0

    /// What ``accessToken(replacing:)`` knows about one pair.
    ///
    /// `pendingReceipts` are provisional: they belong to swaps into the provider that haven't
    /// returned, and are removed when the swap returns. Everything else is adopted: written only
    /// once a swap succeeded (or a refresh failed, or the server expired the pair), never rolled
    /// back, and merged so the order refreshes finish in doesn't matter.
    private struct PairState {
        /// When the refresh responses whose swap stored this pair arrived: the earliest for a
        /// token with `iat` (its claims, so its lifetime, never change), the latest for one without
        /// (see ``earlyRefreshExpiry(of:)``).
        var receivedAt: Date?
        /// Arrivals by swap ID, used only while no receipt is adopted: the provider may expose the
        /// pair before its swap returns.
        var pendingReceipts: [Int: Date] = [:]
        /// When a successful refresh last returned this pair's access token unchanged.
        var unchangedAt: Date?
        /// When an early refresh of this pair last failed transiently; dropped once too old to
        /// pause anything.
        var earlyFailureAt: Date?
        /// The refresh generation when the server rejected this pair's refresh token; dropped
        /// once no in-flight request read at or before it.
        var expiredAt: Int?

        var isEmpty: Bool {
            receivedAt == nil && pendingReceipts.isEmpty && unchangedAt == nil && earlyFailureAt == nil
                && expiredAt == nil
        }
    }

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
        self.init(
            configuration: configuration, tokenProvider: tokenProvider, sessionConfiguration: sessionConfiguration,
            cookieStorage: nil)
    }

    /// - Parameter cookieStorage: The cookie jar to use, for example one shared by the clients
    ///   for the hops of one redirect chain; `nil` for a new jar.
    init(
        configuration: APIClientConfiguration,
        tokenProvider: any TokenProvider,
        sessionConfiguration: URLSessionConfiguration,
        cookieStorage: HTTPCookieStorage?
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        let sessionConfiguration = sessionConfiguration.copy() as? URLSessionConfiguration ?? .absConnection()
        sessionConfiguration.httpCookieStorage = cookieStorage ?? URLSessionConfiguration.ephemeral.httpCookieStorage
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
    /// - Throws: ``CustomHeaderError`` if a header is reserved.
    public func setCustomHeaders(_ headers: [String: String]) throws(CustomHeaderError) {
        try configuration.setCustomHeaders(headers)
    }

    /// Sends `endpoint` and decodes its response.
    public func send<Response>(_ endpoint: Endpoint<Response>) async throws -> Response {
        try await response(for: endpoint).value
    }

    /// Sends `endpoint` and returns the decoded value with its HTTP response.
    public func response<Response>(for endpoint: Endpoint<Response>) async throws -> APIResponse<Response> {
        var refreshed = false
        return try await response(for: endpoint, refreshed: &refreshed)
    }

    /// Sends `endpoint` as ``send(_:)`` does, and reports whether this request's own 401 was
    /// answered by refreshing the tokens it was rejected with (a refresh it started, or one of
    /// those tokens it joined), whether the request then succeeded or failed. A refresh another
    /// request made for its own 401 isn't this request's.
    public func sendTrackingRefresh<Response>(_ endpoint: Endpoint<Response>) async -> RefreshTrackedResult<Response> {
        var refreshed = false
        do {
            let value = try await response(for: endpoint, refreshed: &refreshed).value
            return RefreshTrackedResult(result: .success(value), didRefresh: refreshed)
        } catch {
            return RefreshTrackedResult(result: .failure(error), didRefresh: refreshed)
        }
    }

    /// - Parameter refreshed: Set once a refresh answers this request's 401.
    private func response<Response>(
        for endpoint: Endpoint<Response>, refreshed: inout Bool
    ) async throws -> APIResponse<Response> {
        let request = try makeRequest(for: endpoint)
        let followsRedirects = endpoint.followsRedirects
        let staysOnOrigin = endpoint.staysOnOrigin
        let cookies = writtenCookies(for: endpoint)

        guard endpoint.requiresAuthentication else {
            let reply = try await perform(
                request, followsRedirects: followsRedirects, staysOnOrigin: staysOnOrigin, cookies: cookies)
            return try handle(reply.data, reply.http, for: endpoint)
        }

        // The refresh generation before `tokens` was read. A 401 for `tokens` reuses any refresh
        // completed after that, including one that finished between the read and the send.
        var tokensGeneration = refreshGeneration
        let readGeneration = tokensGeneration
        requestGenerations[readGeneration, default: 0] += 1
        defer { endRequest(readAt: readGeneration) }
        guard var tokens = await tokenProvider.tokens() else { throw APIError.notAuthenticated }
        // The pair a refresh produced for this request. That pair being rejected ends the
        // session; any other pair (for example from a new sign-in) gets its own refresh first.
        var refreshedPair: AuthTokens?
        // Bounds the sends if the tokens keep changing: the original, the retry after a refresh,
        // and two more for a session that replaced the first one and needs its own refresh.
        var sendsLeft = 4
        while true {
            sendsLeft -= 1
            // A refresh that returned the same pair says nothing about the pair's rejection unless it
            // completed after this send.
            let sendGeneration = refreshGeneration
            let reply = try await perform(
                authorized(request, tokens.accessToken), followsRedirects: followsRedirects,
                staysOnOrigin: staysOnOrigin, cookies: cookies)
            // A 401 from a hop that never received the token says nothing about the token.
            guard reply.http.statusCode == 401, !reply.credentialsStripped else {
                return try handle(reply.data, reply.http, for: endpoint)
            }
            let next: AuthTokens
            let nextGeneration = refreshGeneration
            if tokens == refreshedPair {
                // Another request may be refreshing this pair. Its result decides the outcome:
                // expiring now would discard it, and its edge is recorded only once it finishes.
                // If it refreshed the pair after this send, this rejection is answered and the
                // request retries with the current pair; if it failed, the pair is still rejected.
                var refreshedSinceSend = false
                if let flight = refreshFlights[tokens] {
                    refreshJoinObserver?()
                    _ = try? await flight.task.value
                    refreshedSinceSend = completedRefresh(of: tokens, since: sendGeneration)
                }
                // Always handled, whatever the send budget: the refreshed pair is rejected, so the
                // session is over unless a different one replaced it in the meantime.
                let replacement =
                    refreshedSinceSend
                    ? await tokenProvider.tokens() : await expireSession(rejected: tokens, afterRefreshes: true)
                guard let current = replacement else { throw APIError.sessionExpired }
                // A pair another request refreshed from the rejected one is still this chain's
                // refreshed session, so its rejection expires too instead of refreshing again.
                if outcome(current, after: tokens, since: tokensGeneration, sentAt: sendGeneration).didRefresh {
                    refreshedPair = current
                }
                next = current
            } else {
                guard sendsLeft > 0 else { return try handle(reply.data, reply.http, for: endpoint) }
                let outcome = try await refreshedTokens(
                    replacing: tokens, readAt: tokensGeneration, sentAt: sendGeneration)
                if outcome.didRefresh {
                    refreshedPair = outcome.tokens
                    refreshed = true
                }
                next = outcome.tokens
            }
            guard sendsLeft > 0 else { return try handle(reply.data, reply.http, for: endpoint) }
            tokens = next
            tokensGeneration = nextGeneration
            try Task.checkCancellation()
        }
    }

    // MARK: - Token access

    /// The stored access token, or `nil` when signed out. Never makes a network request.
    public func currentAccessToken() async -> String? {
        await tokenProvider.tokens()?.accessToken
    }

    /// An access token for a request made outside this client (downloads, streaming).
    ///
    /// Refreshes go through the same single refresh 401s use, joining one already in flight.
    /// Callers that retry after a 401 should cap their retries: if the server rejects a freshly
    /// refreshed token, each call with it refreshes again.
    ///
    /// - Parameter rejected: `nil` before starting a request: the stored token, refreshed first
    ///   if it expires within ``accessTokenExpiryLeeway`` (see ``earlyRefreshExpiry(of:)``; a
    ///   token without a readable `exp` is returned as is). If that refresh fails with a
    ///   transient error (``APIError/isTransient``), the stored token is still returned if the
    ///   session is unchanged and the token hasn't expired by every measure available, or the
    ///   new session's token if a sign-in replaced it; the same pair isn't refreshed early again
    ///   for ``earlyRefreshRetryInterval`` (or a quarter of its leeway, if shorter). After a
    ///   401, the token the server rejected: refreshed if it is still the stored token
    ///   (whatever earlier failures); otherwise the newer stored token is returned without
    ///   refreshing.
    /// - Throws: ``APIError/notAuthenticated`` when signed out, and on the `nil` path also when
    ///   the user signs out during the refresh. Otherwise whatever the refresh throws, as for a
    ///   401: ``APIError/sessionExpired`` when the server rejects the refresh token, including
    ///   that of a pair refreshed from the stored one by another request (or, with a
    ///   rejected token, when the user signs out during the refresh), other ``APIError``s when
    ///   it fails, and, with a rejected token, `CancellationError` when a sign-out or new sign-in
    ///   replaces the session during the refresh. A caller whose task is cancelled may get
    ///   `CancellationError` on either path.
    public func accessToken(replacing rejected: String?) async throws -> String {
        let readGeneration = refreshGeneration
        requestGenerations[readGeneration, default: 0] += 1
        defer { endRequest(readAt: readGeneration) }
        guard let tokens = await tokenProvider.tokens() else { throw APIError.notAuthenticated }
        if let rejected {
            guard rejected == tokens.accessToken else { return tokens.accessToken }
            // The caller's rejection is treated as if the pair was sent when it was read here.
            let outcome = try await refreshedTokens(replacing: tokens, readAt: readGeneration, sentAt: readGeneration)
            // The shared refresh isn't cancelled with this caller, but its result isn't returned.
            try Task.checkCancellation()
            return outcome.tokens.accessToken
        }
        guard let expiry = earlyRefreshExpiry(of: tokens),
            expiry.expiresAt.timeIntervalSince(now()) <= expiry.leeway
        else { return tokens.accessToken }
        // A refresh that returned the same token can't help again before it expires.
        if let unchangedAt = pairStates[tokens]?.unchangedAt,
            now() < max(expiry.expiresAt, unchangedAt.addingTimeInterval(Self.earlyRefreshRetryInterval))
        {
            return tokens.accessToken
        }
        if let failedAt = pairStates[tokens]?.earlyFailureAt, now() < expiry.validUntil,
            now().timeIntervalSince(failedAt) < min(Self.earlyRefreshRetryInterval, expiry.leeway / 4)
        {
            return tokens.accessToken
        }
        do {
            let outcome = try await refreshedTokens(replacing: tokens, readAt: readGeneration, sentAt: readGeneration)
            // The shared refresh isn't cancelled with this caller, but its result isn't returned.
            try Task.checkCancellation()
            return outcome.tokens.accessToken
        } catch let error as APIError where error.isTransient {
            pairStates[tokens, default: PairState()].earlyFailureAt = now()
            // The session may have ended or changed while the refresh was failing.
            guard let current = await tokenProvider.tokens() else {
                throw await endedSessionError(of: tokens, readAt: readGeneration)
            }
            try Task.checkCancellation()
            guard current == tokens else { return current.accessToken }
            guard now() < expiry.validUntil else { throw error }
            return current.accessToken
        } catch APIError.sessionExpired {
            let error = await endedSessionError(of: tokens, readAt: readGeneration)
            guard error == .notAuthenticated else { throw error }
            // The server didn't reject the refresh token of this pair or of any pair refreshed
            // from it, so the session was ended or replaced locally while the refresh ran.
            guard let current = await tokenProvider.tokens() else { throw error }
            try Task.checkCancellation()
            return current.accessToken
        } catch is CancellationError where !Task.isCancelled {
            // A sign-out or new sign-in replaced the session during the refresh.
            guard let current = await tokenProvider.tokens() else {
                throw await endedSessionError(of: tokens, readAt: readGeneration)
            }
            guard current != tokens else { throw CancellationError() }
            try Task.checkCancellation()
            return current.accessToken
        }
    }

    /// Whether the server ended the session `tokens` started: it rejected the refresh token of
    /// `tokens` or of a pair refreshed from it after generation `generation` (for example by a
    /// request that retried the refreshed pair and got another 401).
    private func serverExpiredSession(of tokens: AuthTokens, readAt generation: Int) -> Bool {
        pairStates.contains { pair, state in
            state.expiredAt != nil
                && (pair == tokens || outcome(pair, after: tokens, since: generation, sentAt: generation).didRefresh)
        }
    }

    /// Why the session `tokens` started is gone for a `nil`-path caller that read it at
    /// `generation`: ``APIError/sessionExpired`` if the server ended it (see
    /// ``serverExpiredSession(of:readAt:)``), otherwise ``APIError/notAuthenticated`` (a local
    /// sign-out). Waits first for expirations in progress, which may have cleared the tokens
    /// without having recorded themselves yet.
    private func endedSessionError(of tokens: AuthTokens, readAt generation: Int) async -> APIError {
        while let pending = pendingExpiries.values.first { _ = await pending.value }
        return serverExpiredSession(of: tokens, readAt: generation) ? .sessionExpired : .notAuthenticated
    }

    /// The most an access token is refreshed ahead of its expiry by ``accessToken(replacing:)``.
    static let accessTokenExpiryLeeway: TimeInterval = 120

    /// The longest ``accessToken(replacing:)`` waits after an early refresh of a pair failed
    /// transiently before refreshing that pair early again.
    static let earlyRefreshRetryInterval: TimeInterval = 30

    /// When `accessToken` expires by this device's clock, and how early to refresh it; `nil` when
    /// it shouldn't be refreshed early. `validUntil` is the latest expiry any measure gives (the
    /// raw `exp`, or the estimate from its receipt), used to decide that it has really expired.
    ///
    /// A token this client received from a refresh is timed from when it arrived: its lifetime
    /// (`exp` − `iat`) after the receipt, so a server clock that differs from this device's doesn't
    /// make it look expired. Without `iat`, such a token that already looked near expiry when it
    /// arrived isn't refreshed early: if it was still valid then, it's refreshed once its `exp`
    /// passes by this device's clock; if not, never. Any other token (loaded from storage) uses `exp` against
    /// this device's clock. The leeway is at most half the lifetime, and a token whose `exp` isn't
    /// after its `iat` is never refreshed early, so a fresh token never immediately looks near
    /// expiry and each pair is replaced by an early refresh at most once (a refresh that fails
    /// transiently is tried again after a pause).
    ///
    /// Limit: a pair this client didn't receive (loaded from storage after launch) can only be
    /// compared with this device's clock, so a server clock behind this device costs one early
    /// refresh after launch, and after a transient failure such a token counts as expired once
    /// its `exp` passes by this device's clock.
    private func earlyRefreshExpiry(
        of tokens: AuthTokens
    ) -> (expiresAt: Date, validUntil: Date, leeway: TimeInterval)? {
        guard let claims = AccessTokenExpiry(token: tokens.accessToken) else { return nil }
        let receivedAt = receipt(of: tokens, hasIssuedAt: claims.issuedAt != nil)
        let rawExpiry = Date(timeIntervalSince1970: claims.expiresAt)
        guard let issuedAt = claims.issuedAt else {
            if let receivedAt, rawExpiry.timeIntervalSince(receivedAt) <= Self.accessTokenExpiryLeeway {
                // Already expired on arrival means the clocks disagree; don't chase it.
                return rawExpiry > receivedAt ? (rawExpiry, rawExpiry, 0) : nil
            }
            return (rawExpiry, rawExpiry, Self.accessTokenExpiryLeeway)
        }
        let lifetime = claims.expiresAt - issuedAt
        guard lifetime > 0 else { return nil }
        let expiresAt = receivedAt?.addingTimeInterval(lifetime) ?? rawExpiry
        return (expiresAt, max(expiresAt, rawExpiry), min(Self.accessTokenExpiryLeeway, lifetime / 2))
    }

    /// Lets tests control the clock used for access token expiry.
    func setNow(_ now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    // MARK: - Token refresh

    /// Returns the tokens to retry with after `rejected` got a 401, where `rejected` was read at
    /// refresh generation `sent`: joins a refresh of the same pair if one is running, reuses one
    /// that completed after the read, or starts one. The result is always the provider's current
    /// pair, so a sign-out or new sign-in since the refresh wins. `sendGeneration` is the generation
    /// when `rejected` was sent (see ``outcome(_:after:since:sentAt:)``).
    private func refreshedTokens(
        replacing rejected: AuthTokens, readAt sent: Int, sentAt sendGeneration: Int
    ) async throws -> RefreshOutcome {
        var hasRereadStaleTokens = false
        while true {
            if let flight = refreshFlights[rejected] {
                refreshJoinObserver?()
                try await flight.task.value
                return try await currentOutcome(after: rejected, since: sent, sentAt: sendGeneration)
            }
            guard let current = await tokenProvider.tokens() else { throw APIError.sessionExpired }
            // A refresh may have started during the read above.
            if refreshFlights[rejected] != nil { continue }
            // Either a completed refresh already produced `current`, or it is a different session.
            let result = outcome(current, after: rejected, since: sent, sentAt: sendGeneration)
            if result.didRefresh || current != rejected { return result }
            // A refresh of `rejected` already finished, so the read predates it; read once more.
            if !hasRereadStaleTokens, completedRefresh(of: rejected, since: sent) {
                hasRereadStaleTokens = true
                continue
            }
            if let flight = refreshFlights[current] {
                refreshJoinObserver?()
                try await flight.task.value
                return try await currentOutcome(after: rejected, since: sent, sentAt: sendGeneration)
            }

            nextFlightID += 1
            let id = nextFlightID
            let task = Task {
                // The flight unregisters itself before it finishes, so no request can join it
                // once it has completed (for example while this request reads the new tokens).
                // Only this flight's entry is removed, never a newer flight for the same pair.
                defer { if refreshFlights[current]?.id == id { refreshFlights[current] = nil } }
                try await tokenProvider.refreshTokens(current) { try await self.refresh(current) }
            }
            refreshFlights[current] = RefreshFlight(id: id, task: task)
            try await task.value
            return try await currentOutcome(after: rejected, since: sent, sentAt: sendGeneration)
        }
    }

    /// Lets tests wait until requests are waiting on a running refresh.
    func observeRefreshJoins(_ observer: @escaping @Sendable () -> Void) {
        refreshJoinObserver = observer
    }

    /// The provider's current pair after a refresh of `rejected` finished.
    private func currentOutcome(
        after rejected: AuthTokens, since sent: Int, sentAt sendGeneration: Int
    ) async throws -> RefreshOutcome {
        guard let current = await tokenProvider.tokens() else { throw APIError.sessionExpired }
        return outcome(current, after: rejected, since: sent, sentAt: sendGeneration)
    }

    /// `current` counts as refreshed only if it descends from `rejected` through one or more
    /// refreshes completed after generation `sent` (including one that returned the same pair);
    /// otherwise it belongs to a different session, or the session needs a new refresh.
    ///
    /// A refresh to a different pair after `sent` must have followed the token read (the read
    /// would otherwise have returned the new pair). A refresh that returned the same pair is
    /// invisible to the read, so it only counts if it completed after `sendGeneration`, the
    /// generation when the rejected pair was sent; one that completed before the send didn't cover
    /// this rejection, which needs a refresh of its own.
    private func outcome(
        _ current: AuthTokens, after rejected: AuthTokens, since sent: Int, sentAt sendGeneration: Int
    ) -> RefreshOutcome {
        var next: [AuthTokens: [AuthTokens]] = [:]
        for refresh in completedRefreshes
        where refresh.generation > (refresh.from == refresh.to ? max(sent, sendGeneration) : sent) {
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

    private func endRequest(readAt generation: Int) {
        requestGenerations[generation, default: 1] -= 1
        if requestGenerations[generation] == 0 { requestGenerations[generation] = nil }
        pruneCompletedRefreshes()
    }

    /// Drops refreshes no in-flight request can consult: those completed at or before the oldest
    /// generation a request read its tokens at (or all of them when no request is in flight).
    /// The one place ``pairStates`` is pruned. Server expiries go with the refreshes: a request
    /// only consults expiries of its own pair or of pairs refreshed from it, all recorded at or
    /// after the generation it read at. Early refresh failures go once too old to pause a retry.
    /// A state with nothing left is dropped; the stored pair keeps its receipt until a refresh
    /// replaces it (see ``adoptRefresh(from:to:receivedAt:)``).
    private func pruneCompletedRefreshes() {
        let oldest = requestGenerations.keys.min() ?? refreshGeneration
        completedRefreshes.removeAll { $0.generation <= oldest }
        let now = now()
        for (pair, var state) in pairStates {
            if let expiredAt = state.expiredAt, requestGenerations.isEmpty || expiredAt < oldest {
                state.expiredAt = nil
            }
            if let failedAt = state.earlyFailureAt,
                now.timeIntervalSince(failedAt) >= Self.earlyRefreshRetryInterval
            {
                state.earlyFailureAt = nil
            }
            pairStates[pair] = state.isEmpty ? nil : state
        }
    }

    /// The receipt lookups use for `tokens`: the adopted one, or while none is adopted, those of
    /// swaps still in progress (the provider may expose the pair before its swap returns).
    private func receipt(of tokens: AuthTokens, hasIssuedAt: Bool) -> Date? {
        guard let state = pairStates[tokens] else { return nil }
        let pending = state.pendingReceipts.values
        return state.receivedAt ?? (hasIssuedAt ? pending.min() : pending.max())
    }

    /// Adopts a refresh from `old` to `new` whose swap succeeded, with its response's arrival.
    /// The same access token keeps its receipt even if the refresh token rotated (including one
    /// whose own swap is still in progress), and is marked unchanged; a replaced pair's adopted
    /// state is dropped. A late completion whose `new` was already refreshed to another pair
    /// adopts nothing for it, so superseded pairs don't come back.
    private func adoptRefresh(from old: AuthTokens, to new: AuthTokens, receivedAt: Date) {
        let unchanged = old.accessToken == new.accessToken
        let hasIssuedAt = AccessTokenExpiry(token: new.accessToken)?.issuedAt != nil
        let inherited = unchanged ? receipt(of: old, hasIssuedAt: hasIssuedAt) : nil
        if old != new {
            pairStates[old]?.receivedAt = nil
            pairStates[old]?.unchangedAt = nil
            pairStates[old]?.earlyFailureAt = nil
        }
        guard !completedRefreshes.contains(where: { $0.from == new && $0.to != new }) else { return }
        let receipts = [pairStates[new]?.receivedAt, inherited, receivedAt].compactMap { $0 }
        var state = pairStates[new] ?? PairState()
        state.receivedAt = hasIssuedAt ? receipts.min() : receipts.max()
        if unchanged { state.unchangedAt = receivedAt }
        pairStates[new] = state
    }

    /// The number of pair states kept, for tests.
    var pairStateCount: Int { pairStates.count }

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
        let receivedAt = now()
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
            // Recorded provisionally before the swap, which may make the new pair visible before
            // it returns, so no lookup sees the new pair without a receipt; adopted only if the
            // swap succeeds.
            nextSwapID += 1
            let swapID = nextSwapID
            pairStates[refreshed, default: PairState()].pendingReceipts[swapID] = receivedAt
            let swapped = await tokenProvider.replaceTokens(expected: tokens, with: refreshed)
            pairStates[refreshed]?.pendingReceipts[swapID] = nil
            // A sign-out or new sign-in during the refresh wins; this request belonged to the
            // session that ended, so it is cancelled rather than retried.
            guard swapped else { throw CancellationError() }
            adoptRefresh(from: tokens, to: refreshed, receivedAt: receivedAt)
            // Recorded before the flight's task finishes, so no request can miss both the
            // flight and its result.
            refreshGeneration += 1
            completedRefreshes.append(CompletedRefresh(from: tokens, to: refreshed, generation: refreshGeneration))
            pruneCompletedRefreshes()
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
    /// - Parameter afterRefreshes: For a 401 to a request, which waits for refreshes of `rejected`
    ///   that other clients of the provider are running. Never from inside a refresh.
    private func expireSession(rejected: AuthTokens, afterRefreshes: Bool = false) async -> AuthTokens? {
        nextExpiryID += 1
        let id = nextExpiryID
        let tokenProvider = tokenProvider
        // Records the expiry before any waiter in ``accessToken(replacing:)`` resumes. A failed
        // compare-and-swap (the session already changed) isn't a server expiry.
        let expiry = Task {
            let expired =
                afterRefreshes
                ? await tokenProvider.expireSessionAfterRefreshes(ifCurrent: rejected)
                : await tokenProvider.expireSession(ifCurrent: rejected)
            if expired {
                pairStates[rejected, default: PairState()].expiredAt = refreshGeneration
            }
            pendingExpiries[id] = nil
            return expired
        }
        pendingExpiries[id] = expiry
        if await expiry.value { return nil }
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
        request.httpShouldHandleCookies = endpoint.sendsCookies && endpoint.withheldCookies.isEmpty
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
        if let cookies = writtenCookies(for: endpoint), let url = request.url {
            // The client writes the cookies itself: the jar's, then the endpoint's own `Cookie`
            // header (custom headers can't set one).
            request.setValue(cookies.header(for: url), forHTTPHeaderField: "Cookie")
        }
        return request
    }

    /// The rule for an endpoint whose cookies the client writes itself (one that withholds some),
    /// or `nil` when `URLSession` handles them (or none are sent).
    private func writtenCookies<Response>(for endpoint: Endpoint<Response>) -> WrittenCookies? {
        guard endpoint.sendsCookies, !endpoint.withheldCookies.isEmpty else { return nil }
        let explicit = endpoint.headers.first { $0.key.lowercased() == "cookie" }?.value
        return WrittenCookies(jar: cookieStorage, withheld: endpoint.withheldCookies, explicit: explicit)
    }

    /// One `Cookie` header from the jar's cookies, minus `withheld` and any named in `explicit`
    /// (so an endpoint's value wins without a duplicate), followed by `explicit`; `nil` if empty.
    static func cookieHeader(jar: [HTTPCookie], withholding withheld: Set<String>, explicit: String?) -> String? {
        let explicitNames = Set(
            (explicit ?? "").split(separator: ";").compactMap { pair in
                pair.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
            })
        let cookies = jar.filter { !withheld.contains($0.name) && !explicitNames.contains($0.name) }
        let parts = [HTTPCookie.requestHeaderFields(with: cookies)["Cookie"], explicit]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
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
    /// - Parameter cookies: For a request whose cookies the client writes, the rule that
    ///   rewrites them on each followed same-origin hop.
    private func perform(
        _ request: URLRequest, followsRedirects: Bool, staysOnOrigin: Bool = false, cookies: WrittenCookies? = nil
    ) async throws -> Reply {
        let chain = followsRedirects ? RedirectChainDelegate(staysOnOrigin: staysOnOrigin, cookies: cookies) : nil
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
