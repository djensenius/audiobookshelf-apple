import ABSCore
import Foundation
import Testing

@Suite struct ServerAddressTests {
    @Test(arguments: [
        ("abs.example.com", "https://abs.example.com"),
        ("  abs.example.com/  ", "https://abs.example.com"),
        ("http://10.0.0.2:13378/", "http://10.0.0.2:13378"),
        ("HTTPS://Abs.Example.COM", "https://abs.example.com"),
        ("localhost:13378", "https://localhost:13378"),
        ("https://example.com/audiobookshelf/", "https://example.com/audiobookshelf"),
        ("https://example.com/Sub/Path//", "https://example.com/Sub/Path"),
        ("https://example.com/my%20books", "https://example.com/my%20books"),
        ("https://example.com/abs?x=1#frag", "https://example.com/abs"),
        ("https://example.com:443/", "https://example.com"),
        ("http://example.com:80", "http://example.com"),
        ("http://example.com:443", "http://example.com:443"),
        ("http://[::1]:13378/", "http://[::1]:13378"),
        ("[2001:DB8::1]:13378/abs", "https://[2001:db8::1]:13378/abs"),
        ("2001:db8::1", "https://[2001:db8::1]"),
        ("2001:db8::1/abs/", "https://[2001:db8::1]/abs"),
        ("fe80::1%en0", "https://[fe80::1%25en0]"),
    ])
    func normalizes(input: String, expected: String) throws {
        let address = try #require(ServerAddress(input))
        #expect(address.description == expected)
        #expect(address.url.absoluteString == expected)
    }

    @Test(arguments: [
        "", "   ", "ftp://example.com", "https://", "https://:80", "https://user:pw@example.com",
        "https://example.com:0", "https://example.com:70000", "file:///tmp",
    ])
    func rejects(input: String) {
        #expect(ServerAddress(input) == nil)
    }

    @Test func recordsWhetherSchemeWasInferred() throws {
        #expect(try #require(ServerAddress("abs.example.com")).isSchemeInferred)
        #expect(try !#require(ServerAddress("https://abs.example.com")).isSchemeInferred)
    }

    @Test func equalityIgnoresHowTheAddressWasTyped() {
        #expect(ServerAddress("abs.example.com/") == ServerAddress("HTTPS://abs.example.com"))
        #expect(Set([ServerAddress("abs.example.com"), ServerAddress("https://abs.example.com:443")]).count == 1)
    }

    @Test func triesHTTPAfterHTTPSOnlyWhenSchemeWasNotTyped() {
        #expect(
            ServerAddress.connectionCandidates(for: "abs.local:13378/abs").map(\.description) == [
                "https://abs.local:13378/abs", "http://abs.local:13378/abs",
            ])
        #expect(
            ServerAddress.connectionCandidates(for: "https://abs.local").map(\.description) == ["https://abs.local"])
        #expect(ServerAddress.connectionCandidates(for: "http://abs.local").map(\.description) == ["http://abs.local"])
        #expect(ServerAddress.connectionCandidates(for: "ftp://abs.local").isEmpty)
    }
}
