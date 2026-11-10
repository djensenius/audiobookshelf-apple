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
}
