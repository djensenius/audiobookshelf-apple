import Foundation

/// Settings for one server connection's ``APIClient``.
public struct APIClientConfiguration: Sendable {
    /// The server address, including any subpath (for example `https://example.com/abs`).
    public var baseURL: URL
    /// Headers the user configured for this server (for example for a reverse proxy). They are
    /// sent with every request, including token refreshes.
    public var customHeaders: [String: String]
    /// The default request timeout in seconds; endpoints may override it.
    public var timeout: TimeInterval

    public init(baseURL: URL, customHeaders: [String: String] = [:], timeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.customHeaders = customHeaders
        self.timeout = timeout
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
