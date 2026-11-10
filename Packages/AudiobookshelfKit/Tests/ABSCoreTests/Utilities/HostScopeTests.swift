import ABSCore
import Testing

@Suite struct HostScopeTests {
    @Test(arguments: [
        // Loopback.
        ("localhost", HostScope.loopback), ("LOCALHOST.", .loopback), ("127.0.0.1", .loopback),
        ("127.8.9.10", .loopback), ("::1", .loopback), ("[::1]", .loopback), ("::ffff:127.0.0.1", .loopback),
        // RFC 1918, link-local and unique-local.
        ("10.0.0.2", .localNetwork), ("10.1", .localNetwork), ("172.16.0.1", .localNetwork),
        ("172.31.255.254", .localNetwork), ("192.168.1.20", .localNetwork), ("169.254.10.1", .localNetwork),
        ("fe80::1", .localNetwork), ("[fe80::1%25en0]", .localNetwork), ("fe80::1%en0", .localNetwork),
        ("fd12:3456::1", .localNetwork), ("::ffff:192.168.1.1", .localNetwork),
        // `.local` and single-label names.
        ("nas.local", .localNetwork), ("NAS.Local.", .localNetwork), ("abs", .localNetwork),
        ("my-server", .localNetwork),
        // Public, including CGNAT (Tailscale) and look-alike names.
        ("abs.example.com", .publicNetwork), ("8.8.8.8", .publicNetwork), ("172.32.0.1", .publicNetwork),
        ("172.15.0.1", .publicNetwork), ("192.169.0.1", .publicNetwork), ("100.64.0.1", .publicNetwork),
        ("2001:db8::1", .publicNetwork), ("local.example.com", .publicNetwork),
        ("example.localhost.com", .publicNetwork),
        ("abs.local.example", .publicNetwork), ("xn--bcher-kva.example", .publicNetwork),
        // Dotless and hexadecimal IPv4, which the system connects to as the address.
        ("134744072", .publicNetwork), ("0x08080808", .publicNetwork), ("2130706433", .loopback),
        ("0x7f.1", .loopback), ("3232235777", .localNetwork),
        // IPv4-compatible (deprecated, not routed to the IPv4 address) and unique-local IPv6.
        ("::a00:1", .publicNetwork), ("::7f00:1", .publicNetwork), ("fc00::1", .localNetwork),
    ])
    func classifies(host: String, expected: HostScope) {
        #expect(HostScope(host: host) == expected)
    }

    @Test(arguments: [
        ("http://abs.example.com", true), ("http://abs.example.com:13378/abs", true), ("http://8.8.8.8", true),
        ("http://100.100.1.2:13378", true), ("https://abs.example.com", false), ("http://192.168.1.20:13378", false),
        ("http://10.0.0.2", false), ("http://nas.local", false), ("http://nas", false),
        ("http://localhost:3333", false),
        ("http://[fe80::1%25en0]:13378", false), ("http://[2001:db8::1]", true), ("https://192.168.1.20", false),
    ])
    func warnsAboutPlainHTTPOnlyOnPublicHosts(address: String, warns: Bool) throws {
        let address = try #require(ServerAddress(address))
        #expect(address.isPlainHTTPOnPublicHost == warns)
    }

    @Test(arguments: [
        // Names may resolve to a local address (split DNS), so they're checked.
        ("abs.example.com", true), ("nas.lan", true), ("abs.home.arpa", true), ("abs.internal", true),
        ("nas", true), ("nas.local", true), ("192.168.1.20", true), ("[fe80::1%25en0]", true), ("fd00::1", true),
        // Loopback and public addresses can't be.
        ("localhost", false), ("127.0.0.1", false), ("::1", false), ("8.8.8.8", false), ("134744072", false),
        ("2001:db8::1", false), ("::a00:1", false),
    ])
    func mayUseLocalNetwork(host: String, expected: Bool) {
        #expect(HostScope.mayUseLocalNetwork(host: host) == expected)
    }

    @Test func isLocalCoversLoopbackAndLocalNetwork() {
        #expect(HostScope.loopback.isLocal && HostScope.localNetwork.isLocal && !HostScope.publicNetwork.isLocal)
    }
}
