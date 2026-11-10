import ABSAPI

/// An in-memory ``TokenProvider`` that records refreshed tokens and session expiry.
actor InMemoryTokenProvider: TokenProvider {
    private(set) var current: AuthTokens?
    private(set) var updates: [AuthTokens] = []
    private(set) var expiredCount = 0

    init(_ tokens: AuthTokens? = AuthTokens(accessToken: "access-1", refreshToken: "refresh-1")) {
        current = tokens
    }

    func tokens() -> AuthTokens? {
        current
    }

    func update(_ tokens: AuthTokens) {
        current = tokens
        updates.append(tokens)
    }

    func sessionExpired() {
        current = nil
        expiredCount += 1
    }
}
