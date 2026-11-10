/// An access and refresh token pair for one server connection.
public struct AuthTokens: Sendable, Hashable {
    public var accessToken: String
    public var refreshToken: String

    public init(accessToken: String, refreshToken: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}

/// Supplies and persists the tokens ``APIClient`` uses for one server connection.
///
/// The app implements this over the Keychain; tests use an in-memory fake.
public protocol TokenProvider: Sendable {
    /// The current tokens, or `nil` when signed out.
    func tokens() async -> AuthTokens?
    /// Persists tokens returned by `POST /auth/refresh`.
    func update(_ tokens: AuthTokens) async
    /// Called once when the server rejects the refresh token. Implementations clear the
    /// stored tokens and return the user to the signed-out state.
    func sessionExpired() async
}
