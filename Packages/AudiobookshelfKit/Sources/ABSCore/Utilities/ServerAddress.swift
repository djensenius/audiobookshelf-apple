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
        if trimmed.contains("://") {
            candidate = trimmed
            isSchemeInferred = false
        } else {
            candidate = "https://" + Self.bracketingBareIPv6(trimmed)
            isSchemeInferred = true
        }

        guard var components = URLComponents(string: candidate),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.percentEncodedHost, !host.isEmpty,
            components.user == nil, components.password == nil
        else { return nil }
        if let port = components.port {
            guard (1...65_535).contains(port) else { return nil }
            if (scheme == "https" && port == 443) || (scheme == "http" && port == 80) {
                components.port = nil
            }
        }

        components.scheme = scheme
        components.percentEncodedHost = host.lowercased()
        components.query = nil
        components.fragment = nil
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path

        guard let url = components.url else { return nil }
        self.url = url
    }

    /// The addresses to try, in order, when connecting to user input. Like the legacy app,
    /// plain `http` is only tried when the user typed no scheme, and only after `https`.
    public static func connectionCandidates(for input: String) -> [ServerAddress] {
        guard let address = ServerAddress(input) else { return [] }
        guard address.isSchemeInferred,
            var components = URLComponents(url: address.url, resolvingAgainstBaseURL: false)
        else { return [address] }
        components.scheme = "http"
        guard let url = components.url, let fallback = ServerAddress(url.absoluteString) else {
            return [address]
        }
        return [address, fallback]
    }

    /// The normalized address, for example `https://abs.example.com/audiobookshelf`.
    public var description: String { url.absoluteString }

    public static func == (lhs: ServerAddress, rhs: ServerAddress) -> Bool { lhs.url == rhs.url }

    public func hash(into hasher: inout Hasher) { hasher.combine(url) }

    /// `fe80::1%en0/abs` becomes `[fe80::1%25en0]/abs`. A bare IPv6 literal can't carry a port.
    private static func bracketingBareIPv6(_ input: String) -> String {
        let hostEnd = input.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? input.endIndex
        let host = input[..<hostEnd]
        guard !host.hasPrefix("["), host.filter({ $0 == ":" }).count >= 2 else { return input }
        let encodedHost = host.replacingOccurrences(of: "%", with: "%25")
        return "[\(encodedHost)]" + input[hostEnd...]
    }
}
