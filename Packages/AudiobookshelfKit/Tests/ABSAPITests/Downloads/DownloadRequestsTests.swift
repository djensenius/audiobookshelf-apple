import Foundation
import Testing

@testable import ABSAPI

@Suite struct DownloadRequestsTests {
    private let configuration = try! APIClientConfiguration(baseURL: URL(string: "https://abs.example.com/abs/")!)

    @Test func encodesIDsAsPathSegments() {
        #expect(DownloadRequests.filePath(itemID: "li_1", ino: "13") == "/api/items/li_1/file/13/download")
        #expect(DownloadRequests.filePath(itemID: "a/b?c", ino: "..") == "/api/items/a%2Fb%3Fc/file/%2E%2E/download")
    }

    @Test func authorizesWithHeadersNotQuery() throws {
        let request = try DownloadRequests.request(
            path: DownloadRequests.filePath(itemID: "li_1", ino: "13"), configuration: configuration, accessToken: "tok"
        )
        #expect(request.url?.absoluteString == "https://abs.example.com/abs/api/items/li_1/file/13/download")
        #expect(request.url?.query() == nil)
        #expect(request.httpMethod == "GET")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test func coverPathAsksForA1200PixelJPEG() {
        #expect(
            DownloadRequests.coverPath(itemID: "li_1", updatedAt: 1_700_000_000_123)
                == "/api/items/li_1/cover?width=1200&format=jpeg&ts=1700000000123")
        #expect(
            DownloadRequests.coverPath(itemID: "a/b?c", updatedAt: 1)
                == "/api/items/a%2Fb%3Fc/cover?width=1200&format=jpeg&ts=1")
    }

    @Test func keepsAStoredQueryOutOfThePath() throws {
        let request = try DownloadRequests.request(
            path: DownloadRequests.coverPath(itemID: "li_1", updatedAt: 1_700_000_000_123),
            configuration: configuration, accessToken: "tok")
        let url = try #require(request.url)
        #expect(
            url.absoluteString
                == "https://abs.example.com/abs/api/items/li_1/cover?width=1200&format=jpeg&ts=1700000000123")
        #expect(url.path() == "/abs/api/items/li_1/cover")
        #expect(url.query() == "width=1200&format=jpeg&ts=1700000000123")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    /// A `+` in a stored query is a plus, not a space, as for every other API query.
    @Test func encodesPlusInAStoredQuery() throws {
        let request = try DownloadRequests.request(
            path: "/api/items/li_1/cover?q=a+b&r=c%2Bd", configuration: configuration, accessToken: "tok")
        #expect(request.url?.query(percentEncoded: true) == "q=a%2Bb&r=c%2Bd")
        #expect(request.url?.path() == "/abs/api/items/li_1/cover")
    }

    /// A background session would forward custom headers to a redirect's new address (#145).
    @Test func refusesConnectionsWithCustomHeaders() throws {
        let proxied = try APIClientConfiguration(
            baseURL: configuration.baseURL, customHeaders: ["CF-Access-Client-Secret": "proxy-secret"])

        #expect(throws: DownloadRequestError.customHeadersRequireRedirectCheck) {
            try DownloadRequests.request(
                path: "/api/items/li_1/file/13/download", configuration: proxied, accessToken: "tok")
        }
        #expect(throws: DownloadRequestError.customHeadersRequireRedirectCheck) {
            try DownloadRequests.request(
                path: DownloadRequests.coverPath(itemID: "li_1", updatedAt: 1), configuration: proxied,
                accessToken: "tok")
        }
    }

    private func redirect(from: String, to: String) throws -> URLRequest? {
        var original = try DownloadRequests.request(
            path: "/api/items/li_1/file/13/download", configuration: configuration, accessToken: "tok")
        // A hop gets the original's headers again, whatever they are.
        original.setValue("proxy-secret", forHTTPHeaderField: "CF-Access-Client-Secret")
        let response = HTTPURLResponse(
            url: URL(string: from)!, statusCode: 302, httpVersion: nil, headerFields: ["Location": to])!
        var proposed = original
        proposed.url = URL(string: to)
        proposed.setValue(nil, forHTTPHeaderField: "Authorization")
        return DownloadRequests.redirect(following: response, to: proposed, original: original)
    }

    @Test func followsSameOriginRedirectsWithCredentials() throws {
        let hop = try #require(
            try redirect(
                from: "https://abs.example.com/abs/api/items/li_1/file/13/download",
                to: "https://abs.example.com/files/13"))
        #expect(hop.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(hop.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "proxy-secret")
    }

    @Test func refusesRedirectsOffOriginOrToHTTP() throws {
        let from = "https://abs.example.com/abs/api/items/li_1/file/13/download"
        #expect(try redirect(from: from, to: "https://cdn.example.net/13") == nil)
        #expect(try redirect(from: from, to: "http://abs.example.com/files/13") == nil)
        #expect(
            DownloadRequests.isSameOrigin(
                URL(string: "http://abs.example.com/a")!, URL(string: "https://abs.example.com/b")!))
        #expect(
            !DownloadRequests.isSameOrigin(
                URL(string: "https://abs.example.com/a")!, URL(string: "https://abs.example.com:8443/b")!))
    }
}
