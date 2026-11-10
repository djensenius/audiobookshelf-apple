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
    /// IPv4 addresses are read as the system reads them, so `10.1` is 10.0.0.1.
    public init(host: String) {
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        while host.hasSuffix(".") { host.removeLast() }

        if let ipv6 = IPv6Address(host), host.contains(":") {
            if let ipv4 = ipv6.asIPv4 {
                self.init(ipv4)
            } else if ipv6.isLoopback {
                self = .loopback
            } else if ipv6.isLinkLocal || ipv6.isUniqueLocal {
                self = .localNetwork
            } else {
                self = .publicNetwork
            }
        } else if host.contains("."), let ipv4 = IPv4Address(host) {
            self.init(ipv4)
        } else if host == "localhost" {
            self = .loopback
        } else if !host.contains(".") || host.hasSuffix(".local") {
            // An empty host also lands here; the address parser never produces one.
            self = .localNetwork
        } else {
            self = .publicNetwork
        }
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

    /// Plain `http` to a host outside the local network, where passwords and tokens could be read
    /// on the way (ADR 0002). The connect screen warns about it but still connects.
    public var isPlainHTTPOnPublicHost: Bool {
        url.scheme == "http" && hostScope == .publicNetwork
    }
}
