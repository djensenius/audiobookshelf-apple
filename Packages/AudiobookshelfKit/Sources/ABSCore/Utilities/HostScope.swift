import Foundation
import Network

/// Where a server's host is, for the plain-HTTP warning and the local network permission check
/// (ADR 0002).
public enum HostScope: Sendable, Hashable {
    /// This device: `localhost`, 127.0.0.0/8 or `::1`.
    case loopback
    /// The local network: a private (RFC 1918), link-local or unique-local address, a `.local`
    /// name, or a single-label name such as `nas`.
    case localNetwork
    /// Anything else, including VPN and carrier-grade NAT addresses.
    case publicNetwork

    /// Classifies a host as written in a URL, with or without IPv6 brackets and zone ID.
    /// IPv4 addresses are read as the system reads them, so `10.1` is 10.0.0.1 and `2130706433`
    /// is 127.0.0.1. Names aren't resolved: a single-label name is local even if a DNS search
    /// domain resolves it to a public host.
    public init(host: String) {
        let host = Self.normalized(host)
        if let scope = Self.addressScope(of: host) {
            self = scope
        } else if host == "localhost" {
            self = .loopback
        } else if !host.contains(".") || host.hasSuffix(".local") {
            // An empty host also lands here; the address parser never produces one.
            self = .localNetwork
        } else {
            self = .publicNetwork
        }
    }

    /// Whether reaching `host` may need local network access: a local address, or any name
    /// but `localhost`, since split DNS, `.lan`, `.home.arpa` or `.internal` names can resolve
    /// to a local address.
    public static func mayUseLocalNetwork(host: String) -> Bool {
        let host = normalized(host)
        if let scope = addressScope(of: host) { return scope == .localNetwork }
        return host != "localhost"
    }

    private static func normalized(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// The scope of an IP address, or `nil` for a name.
    private static func addressScope(of host: String) -> HostScope? {
        if host.contains(":"), let ipv6 = IPv6Address(host) {
            // Not `asIPv4` alone: it also unwraps IPv4-compatible addresses such as `::a00:1`,
            // which aren't routed to the IPv4 address.
            if ipv6.isIPv4Mapped, let ipv4 = ipv6.asIPv4 { return HostScope(ipv4) }
            if ipv6.isLoopback { return .loopback }
            return ipv6.isLinkLocal || ipv6.isUniqueLocal ? .localNetwork : .publicNetwork
        }
        return IPv4Address(host).map(HostScope.init)
    }

    private init(_ address: IPv4Address) {
        let bytes = [UInt8](address.rawValue)
        guard bytes.count == 4 else {
            self = .publicNetwork
            return
        }
        switch (bytes[0], bytes[1]) {
        case (127, _): self = .loopback
        // RFC 1918 and link-local (RFC 3927).
        case (10, _), (172, 16...31), (192, 168), (169, 254): self = .localNetwork
        default: self = .publicNetwork
        }
    }

    /// Whether the host is on this device or the local network.
    public var isLocal: Bool { self != .publicNetwork }
}

extension ServerAddress {
    /// Where the server's host is.
    public var hostScope: HostScope {
        HostScope(host: url.host(percentEncoded: false) ?? "")
    }

    /// Whether a failed connection to the server may be the local network permission (ADR 0002).
    public var mayUseLocalNetwork: Bool {
        HostScope.mayUseLocalNetwork(host: url.host(percentEncoded: false) ?? "")
    }

    /// Plain `http` to a host outside the local network, where passwords and tokens could be read
    /// on the way (ADR 0002). The connect screen warns about it but still connects.
    public var isPlainHTTPOnPublicHost: Bool {
        url.scheme == "http" && hostScope == .publicNetwork
    }
}
