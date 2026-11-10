import Foundation

/// Errors thrown by ``APIClient``.
public enum APIError: Error, Sendable, Equatable {
    /// The endpoint path or query could not be combined with the base URL.
    case invalidURL
    /// The request body could not be encoded.
    case encoding(String)
    /// The connection failed (offline, DNS, TLS, and so on).
    case network(URLError.Code)
    /// The request timed out.
    case timedOut
    /// The server redirected somewhere the client won't follow, such as from `https` to `http`.
    case redirectRefused(status: Int)
    /// The response was not an HTTP response.
    case invalidResponse
    /// An authenticated endpoint was called with no stored tokens.
    case notAuthenticated
    /// The refresh token was rejected; the user must sign in again.
    case sessionExpired
    /// A 401 from an endpoint that does not use the access token, such as a wrong password.
    case unauthorized(message: String?)
    case forbidden(message: String?)
    case notFound
    /// Any other unsuccessful status. `message` is the plain-text body the server sent, if any.
    case http(status: Int, message: String?)
    /// The response body did not match the expected type.
    case decoding(String)

    /// A connection failure, timeout, 408, 429 or 5xx: the server may answer if asked again later.
    /// TLS, ATS and malformed-URL failures aren't transient.
    var isTransient: Bool {
        switch self {
        case .timedOut: true
        case .network(let code): Self.connectivityCodes.contains(code)
        case .http(let status, _): status == 408 || status == 429 || (500..<600).contains(status)
        default: false
        }
    }

    private static let connectivityCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
        .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .timedOut,
    ]
}
