import Foundation
import Testing

@testable import ABSCore

@Suite struct ImageDestinationTests {
    private static let lanServer = "http://192.168.1.5:13378"

    @Test(arguments: [
        "http://127.0.0.1/cover.jpg", "http://2130706433/cover.jpg", "http://localhost:8080/cover.jpg",
        "http://[::1]/cover.jpg", "http://0.0.0.0/cover.jpg", "http://[::ffff:10.0.0.1]/cover.jpg",
        "http://10.0.0.1/cover.jpg", "http://172.16.4.2/cover.jpg", "http://192.168.1.5/cover.jpg",
        "http://169.254.169.254/latest/meta-data", "http://[fe80::1%25en0]/cover.jpg", "http://[fd00::1]/cover.jpg",
        "http://100.100.100.100/cover.jpg", "http://nas.local/cover.jpg", "http://router/cover.jpg",
        "http://printer.home.arpa/cover.jpg", "http://app.localhost/cover.jpg",
        // The configured server's host on another port is another service.
        "http://192.168.1.5:22/cover.jpg",
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
    ])
    func theConfiguredServersOwnOriginIsAllowedOnTheLocalNetwork(server: String, url: String) throws {
        let url = try #require(URL(string: url))
        let server = try #require(URL(string: server))
        #expect(ImageDestination.isAllowed(url, server: server))
        #expect(!ImageDestination.isAllowed(url, server: nil))
    }

    @Test(arguments: ["https://images.example.com/cover.jpg", "http://8.8.8.8/cover.jpg", "https://[2606:4700::1]/c"])
    func publicDestinationsAreAllowed(url: String) throws {
        let url = try #require(URL(string: url))
        #expect(ImageDestination.isAllowed(url, server: URL(string: Self.lanServer)))
        #expect(ImageDestination.isAllowed(url, server: nil))
    }

    @Test(arguments: ["file:///tmp/cover.jpg", "ftp://images.example.com/cover.jpg"])
    func nonHTTPDestinationsAreRejected(url: String) throws {
        let url = try #require(URL(string: url))
        #expect(!ImageDestination.isAllowed(url, server: url))
    }
}
