import Foundation
import Network

/// Where an image request may go (ADR 0005).
///
/// A cover's URL can come from the server (an absolute `coverPath`), so a hostile server could
/// point it, or a redirect, at a service on this device or the user's network and have every
/// library page send it a GET. Image requests therefore reach only the connection's own server
/// (same scheme, host and port, or its `https` upgrade), over `http` or `https` and wherever it
/// is, or an `https` host outside this device and the local network.
///
/// `https` is the defense against DNS rebinding: a public name can resolve to a local address
/// (now or between a check and the connection), and the host's spelling can't show it. Over TLS,
/// a local service can't present a valid certificate for that name, so the connection fails
/// before any HTTP request is sent. App Transport Security doesn't enforce this, since
/// `NSAllowsArbitraryLoads` is on for self-hosted servers, so the check here does. The literal
/// host checks still refuse addresses and names that are local as written.
public enum ImageDestination {
    /// Whether an image request may load `url`. `server` is the connection's address, trusted
    /// wherever it is; with `nil`, only public `https` hosts are allowed.
    public static func isAllowed(_ url: URL, server: URL?) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        if let server, RedirectPolicy.isSameOrigin(server, url) { return true }
        guard scheme == "https", let host = url.host(percentEncoded: false), !host.isEmpty else { return false }
        return !isLocal(host: host)
    }

    /// Whether `host` is on this device or a local or private network: ``HostScope``'s loopback
    /// and local hosts, plus the unspecified address (which reaches this device), carrier-grade
    /// NAT (VPN peers such as Tailscale's), and names reserved for local use.
    static func isLocal(host: String) -> Bool {
        if HostScope(host: host).isLocal { return true }
        var name = host.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        if let zone = name.firstIndex(of: "%") { name = String(name[..<zone]) }
        while name.hasSuffix(".") { name.removeLast() }
        if name.contains(":"), let ipv6 = IPv6Address(name) {
            if ipv6 == .any { return true }
            guard ipv6.isIPv4Mapped, let ipv4 = ipv6.asIPv4 else { return false }
            return isLocal(ipv4)
        }
        if let ipv4 = IPv4Address(name) { return isLocal(ipv4) }
        return [".localhost", ".home.arpa", ".internal", ".lan"].contains { name.hasSuffix($0) }
    }

    /// 0.0.0.0/8 and 100.64.0.0/10, which ``HostScope`` counts as public.
    private static func isLocal(_ address: IPv4Address) -> Bool {
        let bytes = [UInt8](address.rawValue)
        guard bytes.count == 4 else { return false }
        return bytes[0] == 0 || (bytes[0] == 100 && (64...127).contains(bytes[1]))
    }
}
