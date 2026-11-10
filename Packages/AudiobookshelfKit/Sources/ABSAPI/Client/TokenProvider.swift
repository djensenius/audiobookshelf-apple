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
/// The app implements this over the Keychain; tests use an in-memory fake. The two mutating
/// requirements are compare-and-swap operations: each compares the stored pair with the one the
/// client expects and changes it in the same atomic step, so a sign-in or sign-out that lands
/// while a request is in flight is never overwritten or cleared by that request.
public protocol TokenProvider: Sendable {
    /// The current tokens, or `nil` when signed out.
    func tokens() async -> AuthTokens?

    /// Atomically replaces `expected` with `new` (tokens returned by `POST /auth/refresh`) and
    /// returns `true`; returns `false` without changing anything if the stored pair is no
    /// longer `expected` (the user signed out or signed in again).
    ///
    /// The server has already rotated the refresh token, so a successful swap must not be lost:
    /// if persisting fails, keep the pair in memory and keep returning it from ``tokens()``.
    /// The Keychain implementation must use an after-first-unlock accessibility class so
    /// refreshes work in the background while the device is locked (for example during
    /// playback).
    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool

    /// Atomically clears the stored tokens and returns the user to the signed-out state if
    /// they still equal `rejected` (the server rejected its refresh token), returning `true`.
    /// Returns `false` without changing anything if the stored pair is different.
    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool
}
