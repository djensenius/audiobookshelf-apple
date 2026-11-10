import ABSCore
import Foundation

/// Server discovery, local sign-in, and sign-out endpoints. OpenID sign-in is separate.
///
/// The connection's custom headers are added by ``APIClient`` to every request, including
/// these; ``APIClientConfiguration`` never lets them set `Authorization` or `Cookie`.
public enum AuthEndpoints {
    /// `GET /status`, unauthenticated: the server version, whether it is initialised, and its
    /// sign-in methods.
    public static func status() -> Endpoint<ServerStatus> {
        Endpoint(.get, "/status", requiresAuthentication: false)
    }

    /// `GET /ping`, unauthenticated: `{"success":true}`.
    public static func ping() -> Endpoint<PingResponse> {
        Endpoint(.get, "/ping", requiresAuthentication: false)
    }

    /// `POST /login` with a username and password. `x-return-tokens: true` makes the server
    /// return the refresh token in the body instead of a cookie; see
    /// ``AuthResponse/sessionTokens``. A wrong password is a 401 with the body
    /// `Unauthorized`; too many attempts are a 429.
    public static func login(username: String, password: String) -> Endpoint<AuthResponse> {
        Endpoint(
            .post, "/login",
            headers: ["x-return-tokens": "true"],
            body: LoginRequest(username: username, password: password),
            requiresAuthentication: false,
            // The legacy app allows 20 s: the server hashes the password with bcrypt.
            timeout: 20
        )
    }

    /// `POST /api/authorize`: the signed-in user and server settings for the current access
    /// token. The server only routes `POST`. The response carries no new tokens.
    public static func authorize() -> Endpoint<AuthResponse> {
        Endpoint(.post, "/api/authorize")
    }

    /// `POST /logout`: invalidates the session that `refreshToken` belongs to. The server reads
    /// it from the `x-refresh-token` header (or the cookie the app doesn't use). `/logout` is not
    /// behind the access-token check, so no access token is sent and a 401 never triggers a
    /// refresh.
    public static func logout(refreshToken: String) -> Endpoint<LogoutResponse> {
        Endpoint(
            .post, "/logout", headers: ["x-refresh-token": refreshToken], requiresAuthentication: false)
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
