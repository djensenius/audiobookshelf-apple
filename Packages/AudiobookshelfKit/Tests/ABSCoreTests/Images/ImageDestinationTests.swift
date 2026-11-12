import Foundation
import Testing

@testable import ABSCore

@Suite struct ImageDestinationTests {
    private static let lanServer = "http://192.168.1.5:13378"

    @Test(arguments: [
        "https://127.0.0.1/cover.jpg", "https://2130706433/cover.jpg", "https://localhost:8080/cover.jpg",
        "https://[::1]/cover.jpg", "https://0.0.0.0/cover.jpg", "https://[::ffff:10.0.0.1]/cover.jpg",
        "https://10.0.0.1/cover.jpg", "https://172.16.4.2/cover.jpg", "https://192.168.1.5/cover.jpg",
        "https://169.254.169.254/latest/meta-data", "https://[fe80::1%25en0]/cover.jpg", "https://[fd00::1]/cover.jpg",
        "https://100.100.100.100/cover.jpg", "https://nas.local/cover.jpg", "https://router/cover.jpg",
        "https://printer.home.arpa/cover.jpg", "https://app.localhost/cover.jpg",
        // The configured server's host on another port is another service.
        "https://192.168.1.5:22/cover.jpg",
    ])
    func localDestinationsAreRejected(url: String) throws {
        let url = try #require(URL(string: url))
        #expect(!ImageDestination.isAllowed(url, server: URL(string: Self.lanServer)))
        #expect(!ImageDestination.isAllowed(url, server: nil))
    }

    @Test(arguments: [
        (lanServer, "http://192.168.1.5:13378/api/items/li1/cover"),
        ("http://nas.local/abs", "https://nas.local/covers/1.jpg"),
        ("http://localhost:3333", "http://localhost:3333/covers/1.jpg"),
        ("http://abs.example:8080/abs", "http://abs.example:8080/covers/1.jpg"),
    ])
    func theConfiguredServersOwnOriginIsAllowedOnTheLocalNetwork(server: String, url: String) throws {
        let url = try #require(URL(string: url))
        let server = try #require(URL(string: server))
        #expect(ImageDestination.isAllowed(url, server: server))
        #expect(!ImageDestination.isAllowed(url, server: nil))
    }

    @Test(arguments: ["https://images.example.com/cover.jpg", "https://8.8.8.8/cover.jpg", "https://[2606:4700::1]/c"])
    func publicDestinationsAreAllowed(url: String) throws {
        let url = try #require(URL(string: url))
        #expect(ImageDestination.isAllowed(url, server: URL(string: Self.lanServer)))
        #expect(ImageDestination.isAllowed(url, server: nil))
    }

    /// Over plain `http`, a public name could resolve to a local service; TLS refuses it.
    @Test(arguments: ["http://images.example.com/cover.jpg", "http://8.8.8.8/cover.jpg", "http://[2606:4700::1]/c"])
    func plainHTTPOffTheServersOriginIsRejected(url: String) throws {
        let url = try #require(URL(string: url))
        #expect(!ImageDestination.isAllowed(url, server: URL(string: Self.lanServer)))
        #expect(!ImageDestination.isAllowed(url, server: nil))
        // Another port or host of an `http` server is another origin.
        #expect(!ImageDestination.isAllowed(url, server: URL(string: "http://abs.example:8080")))
    }

    @Test(arguments: ["file:///tmp/cover.jpg", "ftp://images.example.com/cover.jpg"])
    func nonHTTPDestinationsAreRejected(url: String) throws {
        let url = try #require(URL(string: url))
        #expect(!ImageDestination.isAllowed(url, server: url))
    }
}
