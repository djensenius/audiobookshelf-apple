import ABSCore
import Foundation
import Testing

@testable import ABSRealtime

@Suite struct SocketEndpointTests {
    @Test(arguments: [
        ("https://abs.example.com", "wss://abs.example.com/socket.io/?EIO=4&transport=websocket"),
        ("http://192.168.1.2:13378/", "ws://192.168.1.2:13378/socket.io/?EIO=4&transport=websocket"),
        ("https://example.com/audiobookshelf", "wss://example.com/audiobookshelf/socket.io/?EIO=4&transport=websocket"),
        ("https://example.com/a/b//?x=1#frag", "wss://example.com/a/b/socket.io/?EIO=4&transport=websocket"),
        ("wss://example.com:8443/abs", "wss://example.com:8443/abs/socket.io/?EIO=4&transport=websocket"),
        ("https://host/abs%2Ftenant", "wss://host/abs%2Ftenant/socket.io/?EIO=4&transport=websocket"),
        ("https://host/my%20books/", "wss://host/my%20books/socket.io/?EIO=4&transport=websocket"),
    ])
    func buildsSocketURL(address: String, expected: String) throws {
        let url = try #require(URL(string: address))
        #expect(SocketEndpoint.url(forServerAddress: url)?.absoluteString == expected)
    }

    /// The token goes in the `auth` event, never in the URL, so the endpoint (and any error that
    /// quotes it) can't carry one: an address's query, fragment and user info are dropped (#662).
    @Test(arguments: [
        "https://abs.example/abs?token=0paque-secret",
        "https://abs.example/abs/?access_token=0paque-secret&x=1#token=0paque-secret",
        "https://david:0paque-secret@abs.example/abs",
    ])
    func socketURLCarriesNoCredentials(address: String) throws {
        let address = try #require(URL(string: address))
        let url = try #require(SocketEndpoint.url(forServerAddress: address))
        #expect(url.absoluteString == "wss://abs.example/abs/socket.io/?EIO=4&transport=websocket")
        let error = URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: url])
        #expect(!Log.redacted(error).contains("0paque"))
    }

    @Test(arguments: ["ftp://example.com", "file:///tmp/abs", "example.com"])
    func rejectsUnsupportedAddresses(address: String) throws {
        let url = try #require(URL(string: address))
        #expect(SocketEndpoint.url(forServerAddress: url) == nil)
    }

    @Test func dropsAuthorizationAndCookieHeaders() {
        let headers = SocketEndpoint.filteredHeaders([
            "authorization": "Bearer x",
            "Cookie": "a=b",
            "CF-Access-Client-Id": "id",
        ])
        #expect(headers == ["CF-Access-Client-Id": "id"])
    }

    @Test func dropsWebSocketHandshakeHeadersAndDeduplicatesNames() {
        let headers = SocketEndpoint.filteredHeaders([
            "Host": "evil.example.com",
            "connection": "close",
            "Upgrade": "h2c",
            "Sec-WebSocket-Key": "k",
            "sec-websocket-protocol": "p",
            "X-Token": "upper",
            "x-token": "lower",
            "X-Other": "o",
        ])
        #expect(headers == ["X-Other": "o", "X-Token": "upper"])
    }
}
