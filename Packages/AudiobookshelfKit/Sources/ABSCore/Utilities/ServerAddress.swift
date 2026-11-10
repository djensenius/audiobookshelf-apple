import Foundation

/// A normalized Audiobookshelf server base URL.
///
/// Normalization: trims whitespace, adds `https://` when no scheme is given, accepts only
/// `http` and `https`, lowercases the scheme and host, brackets bare IPv6 literals, drops the
/// default port, the query and the fragment, and keeps any subpath (reverse-proxy installs)
/// without trailing slashes. Addresses with credentials or an invalid port are rejected.
public struct ServerAddress: Sendable, Hashable, CustomStringConvertible {
    public let url: URL

    /// Whether the input had no scheme and `https` was assumed.
    public let isSchemeInferred: Bool

    public init?(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if trimmed.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil {
            candidate = trimmed
            isSchemeInferred = false
        } else {
            // `https:/host` or `http:host` is a mistyped scheme, not a host named `https`.
            let lowercased = trimmed.lowercased()
            guard !lowercased.hasPrefix("http:"), !lowercased.hasPrefix("https:") else { return nil }
            candidate = "https://" + Self.bracketingBareIPv6(trimmed)
            isSchemeInferred = true
        }

        guard var components = URLComponents(string: candidate),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.encodedHost, !host.isEmpty,
            components.user == nil, components.password == nil
        else { return nil }
        // `port` is nil for a port that overflows `Int`; only an empty port (`host:`) may be nil.
        if components.port == nil, let string = components.string, let range = components.rangeOfPort,
            !string[range].isEmpty
        {
            return nil
        }
        if let port = components.port {
            guard (1...65_535).contains(port) else { return nil }
            if (scheme == "https" && port == 443) || (scheme == "http" && port == 80) {
                components.port = nil
            }
        }

        components.scheme = scheme
        components.encodedHost = Self.lowercasingHost(host)
        components.query = nil
        components.fragment = nil
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path

        guard let url = components.url else { return nil }
        self.url = url
    }

    /// The addresses to try, in order, when connecting to user input. Like the legacy app
    /// (`ServerConnectForm.vue` `tryServerUrl`), plain `http` is only tried when the user typed
    /// no scheme, and only after `https`. Callers fall back to `http` only on a transport
    /// failure, never after an HTTP status response, and never follow an `https` → `http`
    /// redirect when the user typed `https`.
    public static func connectionCandidates(for input: String) -> [ServerAddress] {
        guard let address = ServerAddress(input) else { return [] }
        // Build the fallback from the typed input, not from `address`: an explicit `:443` was
        // dropped there as the https default but is a real port for http.
        let typed = bracketingBareIPv6(input.trimmingCharacters(in: .whitespacesAndNewlines))
        guard address.isSchemeInferred, let fallback = ServerAddress("http://" + typed) else {
            return [address]
        }
        return [address, fallback]
    }

    /// The normalized address, for example `https://abs.example.com/audiobookshelf`.
    public var description: String { url.absoluteString }

    public static func == (lhs: ServerAddress, rhs: ServerAddress) -> Bool { lhs.url == rhs.url }

    public func hash(into hasher: inout Hasher) { hasher.combine(url) }

    /// Lowercases the host, except an IPv6 zone ID (after `%25`), which is case-sensitive
    /// (RFC 6874).
    private static func lowercasingHost(_ host: String) -> String {
        guard host.hasPrefix("["), let zone = host.range(of: "%25") else { return host.lowercased() }
        return host[..<zone.lowerBound].lowercased() + host[zone.lowerBound...]
    }

    /// `fe80::1%en0/abs` becomes `[fe80::1%25en0]/abs`. A bare IPv6 literal can't carry a port.
    private static func bracketingBareIPv6(_ input: String) -> String {
        let hostEnd = input.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? input.endIndex
        let host = input[..<hostEnd]
        guard !host.hasPrefix("["), host.filter({ $0 == ":" }).count >= 2 else { return input }
        let encodedHost = host.replacingOccurrences(of: "%", with: "%25")
        return "[\(encodedHost)]" + input[hostEnd...]
    }
}
