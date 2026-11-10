import Foundation

/// An HTTP method used by ``Endpoint``.
public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// A response type for endpoints whose body is ignored (for example a plain-text `OK`).
public struct EmptyResponse: Decodable, Sendable, Equatable {
    public init() {}
}

/// A typed description of one server request.
///
/// `path` is relative to the server's base URL, so `/api/libraries` on a server at
/// `https://example.com/abs` resolves to `https://example.com/abs/api/libraries`.
/// Use `EmptyResponse` to ignore the body and `Data` to receive it unparsed.
public struct Endpoint<Response: Decodable & Sendable>: Sendable {
    public var method: HTTPMethod
    public var path: String
    public var query: [URLQueryItem]
    public var headers: [String: String]
    /// Encoded as JSON with the client's encoder.
    public var body: (any Encodable & Sendable)?
    /// Sends the access token and refreshes it on a 401. Turn off for login and other
    /// pre-authentication requests.
    public var requiresAuthentication: Bool
    /// Overrides the client's default request timeout.
    public var timeout: TimeInterval?
    /// When `false`, redirects are not followed and a 3xx response is returned as a success so
    /// the caller can read its `Location` header.
    public var followsRedirects: Bool
    /// When `true` (and ``followsRedirects`` is), only redirects that stay on the server's
    /// origin are followed. A hop off the origin, which would be stripped of the request's
    /// headers and cookies, is declined and the 3xx surfaces as ``APIError/redirectRefused(status:)``
    /// instead of the other origin's reply being reported as this request's result.
    public var staysOnOrigin: Bool
    /// When `false`, the request neither sends nor stores the connection's cookies.
    public var sendsCookies: Bool
    /// Names of the connection's cookies to leave off this request; the others are still sent.
    /// When not empty, the request's cookies are written by the client, including on each followed
    /// same-origin redirect, whose `Set-Cookie` (except the withheld names) is stored in the jar
    /// first; the final response's cookies are not stored.
    public var withheldCookies: Set<String>

    public init(
        _ method: HTTPMethod = .get,
        _ path: String,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: (any Encodable & Sendable)? = nil,
        requiresAuthentication: Bool = true,
        timeout: TimeInterval? = nil,
        followsRedirects: Bool = true,
        staysOnOrigin: Bool = false,
        sendsCookies: Bool = true,
        withheldCookies: Set<String> = [],
        as response: Response.Type = Response.self
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.requiresAuthentication = requiresAuthentication
        self.timeout = timeout
        self.followsRedirects = followsRedirects
        self.staysOnOrigin = staysOnOrigin
        self.sendsCookies = sendsCookies
        self.withheldCookies = withheldCookies
    }
}

/// A decoded value together with the HTTP response it came from.
public struct APIResponse<Value: Sendable>: Sendable {
    public let value: Value
    public let httpResponse: HTTPURLResponse
}
