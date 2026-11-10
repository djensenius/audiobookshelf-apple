import ABSCore
import Foundation

/// Server discovery, local sign-in, and sign-out endpoints. OpenID sign-in is separate.
///
/// The connection's custom headers are added by ``APIClient`` to every request, including
/// these; ``APIClientConfiguration`` never lets them set `Authorization` or `Cookie`.
public enum AuthEndpoints {
    /// `GET /status`, unauthenticated: the server version, whether it is initialised, and its
    /// sign-in methods. It is the first request to a new address, so it times out sooner than
    /// other requests and an unreachable `https` port falls back to `http` quickly.
    public static func status() -> Endpoint<ServerStatus> {
        Endpoint(.get, "/status", requiresAuthentication: false, timeout: statusTimeout)
    }

    /// The `GET /status` timeout in seconds (the legacy app used 6).
    static let statusTimeout: TimeInterval = 10

    /// `GET /ping`, unauthenticated: `{"success":true}`.
    public static func ping() -> Endpoint<PingResponse> {
        Endpoint(.get, "/ping", requiresAuthentication: false)
    }

    /// `POST /login` with a username and password. `x-return-tokens: true` makes the server
    /// return the refresh token in the body instead of a cookie; see
    /// ``AuthResponse/sessionTokens``. A wrong password is a 401 with the body
    /// `Unauthorized`; too many attempts are a 429.
    ///
    /// Redirects are not followed, so the password is never re-sent to another address by a
    /// 307 or 308; a 3xx reaches the caller and fails to decode. ``ServerValidator`` reports it
    /// as ``ServerValidationError/loginRedirected``.
    public static func login(username: String, password: String) -> Endpoint<AuthResponse> {
        Endpoint(
            .post, "/login",
            headers: ["x-return-tokens": "true"],
            body: LoginRequest(username: username, password: password),
            requiresAuthentication: false,
            // The legacy app allows 20 s: the server hashes the password with bcrypt.
            timeout: 20,
            followsRedirects: false
        )
    }

    /// `POST /api/authorize`: the signed-in user and server settings for the current access
    /// token. The server only routes `POST`. The response carries no new tokens.
    ///
    /// Redirects are not followed: a hop to another origin is sent without the token, so a 200
    /// from it would not prove the session is valid. A 3xx reaches the caller and fails to
    /// decode; ``ServerValidator/authorize(with:)`` reports it as
    /// ``ServerValidationError/loginRedirected``.
    public static func authorize() -> Endpoint<AuthResponse> {
        Endpoint(.post, "/api/authorize", followsRedirects: false)
    }

    /// `POST /logout`: invalidates the session that `refreshToken` belongs to.
    ///
    /// The server prefers a `refresh_token` cookie over the `x-refresh-token` header, and the
    /// connection's cookie jar can hold one (`/auth/refresh` sets it), so that cookie is withheld
    /// to make the header token the one invalidated. The jar's other cookies are sent: a proxy in
    /// front of the server may need its own, and `connect.sid` is this connection's own server
    /// session, which logging out should end. `/logout` is not behind the access-token check,
    /// so no access token is sent and a 401 never triggers a refresh.
    ///
    /// For an OpenID session, pass the cookies saved at sign-in: they're added to the jar's in
    /// the `Cookie` header (replacing any jar cookies of the same names), so the server returns
    /// the identity provider's end-session URL in ``LogoutResponse/redirectURL``.
    public static func logout(
        refreshToken: String, openIDSession: OpenIDSessionCookies? = nil
    ) -> Endpoint<LogoutResponse> {
        var headers = ["x-refresh-token": refreshToken]
        if let openIDSession { headers["Cookie"] = openIDSession.headerValue }
        return Endpoint(
            .post, "/logout", headers: headers, requiresAuthentication: false, withheldCookies: ["refresh_token"])
    }
}

/// The `POST /login` body.
struct LoginRequest: Encodable, Sendable {
    let username: String
    let password: String
}

/// The `GET /ping` response.
public struct PingResponse: Decodable, Sendable, Equatable {
    public var success: Bool

    public init(success: Bool) {
        self.success = success
    }
}

/// The `POST /logout` response.
public struct LogoutResponse: Decodable, Sendable, Equatable {
    /// The OpenID provider's end-session URL for OpenID sessions; `nil` for local sign-in.
    public var redirectURL: String?

    public init(redirectURL: String? = nil) {
        self.redirectURL = redirectURL
    }

    enum CodingKeys: String, CodingKey {
        case redirectURL = "redirect_url"
    }
}

extension AuthResponse {
    /// The access and refresh tokens from `POST /login` (with `x-return-tokens: true`), as the
    /// ``AuthTokens`` pair ``APIClient`` uses; `nil` when either token is missing, as on
    /// `/api/authorize`.
    public var sessionTokens: AuthTokens? {
        guard let tokens, let refreshToken = tokens.refreshToken else { return nil }
        return AuthTokens(accessToken: tokens.accessToken, refreshToken: refreshToken)
    }
}
