import Foundation
import Testing

@testable import ABSAPI

@Suite struct DownloadRequestsTests {
    private let configuration = try! APIClientConfiguration(
        baseURL: URL(string: "https://abs.example.com/abs/")!,
        customHeaders: ["CF-Access-Client-Secret": "proxy-secret"])

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
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "proxy-secret")
    }

    private func redirect(from: String, to: String) throws -> URLRequest? {
        let original = try DownloadRequests.request(
            path: "/api/items/li_1/file/13/download", configuration: configuration, accessToken: "tok")
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
