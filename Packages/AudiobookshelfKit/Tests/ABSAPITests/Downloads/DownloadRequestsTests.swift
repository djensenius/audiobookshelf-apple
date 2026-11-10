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

    /// A background session would forward custom headers to a redirect's new address (#145).
    @Test func refusesConnectionsWithCustomHeaders() throws {
        let proxied = try APIClientConfiguration(
            baseURL: configuration.baseURL, customHeaders: ["CF-Access-Client-Secret": "proxy-secret"])

        #expect(throws: DownloadRequestError.customHeadersRequireRedirectCheck) {
            try DownloadRequests.request(
                path: "/api/items/li_1/file/13/download", configuration: proxied, accessToken: "tok")
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
