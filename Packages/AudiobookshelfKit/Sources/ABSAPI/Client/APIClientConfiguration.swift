import Foundation

/// Settings for one server connection's ``APIClient``.
public struct APIClientConfiguration: Sendable {
    /// The server address, including any subpath (for example `https://example.com/abs`).
    public var baseURL: URL
    /// Headers the user configured for this server (for example for a reverse proxy). They are
    /// sent with every request to the server's origin, including token refreshes.
    public private(set) var customHeaders: [String: String]
    /// The default request timeout in seconds; endpoints may override it.
    public var timeout: TimeInterval

    /// - Throws: ``CustomHeaderError`` if a custom header is reserved.
    public init(
        baseURL: URL,
        customHeaders: [String: String] = [:],
        timeout: TimeInterval = 30
    ) throws(CustomHeaderError) {
        try Self.validate(customHeaders: customHeaders)
        self.baseURL = baseURL
        self.customHeaders = customHeaders
        self.timeout = timeout
    }

    /// - Throws: ``CustomHeaderError`` if a custom header is reserved.
    public mutating func setCustomHeaders(_ headers: [String: String]) throws(CustomHeaderError) {
        try Self.validate(customHeaders: headers)
        customHeaders = headers
    }

    /// Header names, lowercased, that users may not set: the sign-in headers the client manages,
    /// and connection and framing headers that `URLSession` manages or a proxy would misread.
    public static let reservedHeaderNames: Set<String> = [
        "authorization", "cookie", "x-refresh-token", "proxy-authorization", "proxy-authenticate",
        "www-authenticate", "host", "connection", "keep-alive", "upgrade", "te", "transfer-encoding",
        "content-length",
    ]

    /// Checks custom headers before they are saved, so the connect screen can explain the
    /// problem.
    public static func validate(customHeaders: [String: String]) throws(CustomHeaderError) {
        for name in customHeaders.keys.sorted() where reservedHeaderNames.contains(name.lowercased()) {
            throw .reserved(name: name)
        }
    }
}

/// A custom header the user can't configure.
public enum CustomHeaderError: Error, Sendable, Equatable, LocalizedError {
    /// One of ``APIClientConfiguration/reservedHeaderNames``.
    case reserved(name: String)

    public var errorDescription: String? {
        switch self {
        case .reserved(let name) where ["authorization", "cookie", "x-refresh-token"].contains(name.lowercased()):
            "The \(name) header is used for your Audiobookshelf sign-in. Use a different header or a service token."
        case .reserved(let name):
            "The \(name) header is managed by the connection and can't be set."
        }
    }
}

extension URLSessionConfiguration {
    /// An ephemeral configuration with its own in-memory cookie jar, so each server connection
    /// keeps its cookies (such as the OIDC session cookie) separate from every other one.
    public static func absConnection() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        return configuration
    }
}
