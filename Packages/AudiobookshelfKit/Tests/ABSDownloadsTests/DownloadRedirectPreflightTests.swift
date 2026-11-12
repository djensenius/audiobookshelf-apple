import ABSAPI
import Foundation
import Synchronization
import Testing

@testable import ABSDownloads

/// Answers the preflight's requests for registered hosts and records them, by host. Like
/// `URLSession`, a redirect proposes the request with all its headers at the new URL.
final class PreflightStubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case status(Int)
        case redirect(to: String)
        case fail(URLError.Code)
    }

    typealias Handler = @Sendable (URLRequest) -> Reply

    private static let routes = Mutex<[String: (handler: Handler, requests: [URLRequest])]>([:])

    static func register(host: String, handler: @escaping Handler) {
        routes.withLock { $0[host] = (handler, []) }
    }

    static func requests(host: String) -> [URLRequest] {
        routes.withLock { $0[host]?.requests ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return routes.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
            let handler = Self.routes.withLock({ routes -> Handler? in
                routes[host]?.requests.append(request)
                return routes[host]?.handler
            })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch handler(request) {
        case .status(let status):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let location):
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
            var proposed = request
            proposed.url = URL(string: location)
            client?.urlProtocol(self, wasRedirectedTo: proposed, redirectResponse: response)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

@Suite struct DownloadRedirectPreflightTests {
    private let host = "\(UUID().uuidString.lowercased()).preflight.test"
    private let otherHost = "\(UUID().uuidString.lowercased()).elsewhere.test"
    private let secret = "CF-Access-Client-Secret"

    private var preflight: DownloadRedirectPreflight {
        DownloadRedirectPreflight {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PreflightStubProtocol.self]
            return configuration
        }
    }

    /// A download request as the engine makes it: custom headers and the bearer header.
    private func download(_ path: String = "/file") throws -> URLRequest {
        let configuration = try APIClientConfiguration(
            baseURL: URL(string: "https://\(host)/abs")!, customHeaders: [secret: "proxy-secret"])
        return try DownloadRequests.request(path: path, configuration: configuration, accessToken: "tok")
    }

    private func url(_ path: String) -> URL { URL(string: "https://\(host)/abs\(path)")! }

    @Test func clearsARequestWithoutRedirects() async throws {
        PreflightStubProtocol.register(host: host) { _ in .status(200) }
        let request = try download()

        let cleared = try await preflight.check(request)

        #expect(cleared == request)
        let sent = PreflightStubProtocol.requests(host: host)
        #expect(sent.map(\.url) == [url("/file")])
        #expect(sent.map(\.httpMethod) == ["HEAD"])
        #expect(sent.first?.value(forHTTPHeaderField: secret) == "proxy-secret")
        #expect(sent.first?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    /// Same-origin hops are followed with every header, and the task starts at the last URL.
    @Test func followsSameOriginRedirectsToTheFinalURL() async throws {
        let final = url("/media/file.mp3")
        PreflightStubProtocol.register(host: host) { request in
            request.url?.path() == "/abs/file" ? .redirect(to: final.absoluteString) : .status(200)
        }
        let request = try download()

        let cleared = try await preflight.check(request)

        #expect(cleared.url == final)
        #expect(cleared.httpMethod == "GET")
        #expect(cleared.allHTTPHeaderFields == request.allHTTPHeaderFields)
        let sent = PreflightStubProtocol.requests(host: host)
        #expect(sent.map(\.url) == [url("/file"), final])
        #expect(sent.last?.value(forHTTPHeaderField: secret) == "proxy-secret")
        #expect(sent.last?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    /// A hop to another host, another port, or from `https` to `http` is refused before it is
    /// sent: the other origin never sees a request, so never the custom headers either.
    @Test(arguments: ["https://OTHER/file", "https://HOST:8443/file", "http://HOST/file"])
    func refusesAnOffOriginRedirectBeforeSendingIt(target: String) async throws {
        let target = URL(
            string: target.replacingOccurrences(of: "OTHER", with: otherHost).replacingOccurrences(
                of: "HOST", with: host))!
        PreflightStubProtocol.register(host: host) { request in
            request.url?.path() == "/abs/file" ? .redirect(to: target.absoluteString) : .status(200)
        }
        PreflightStubProtocol.register(host: otherHost) { _ in .status(200) }

        await #expect(throws: DownloadRedirectPreflightError.offOrigin(target)) {
            try await preflight.check(try download())
        }
        #expect(PreflightStubProtocol.requests(host: host).map(\.url) == [url("/file")])
        #expect(PreflightStubProtocol.requests(host: otherHost).isEmpty)
    }

    /// A server that rejects `HEAD` is asked for the first byte instead, redirects included.
    @Test(arguments: [405, 501])
    func fallsBackToARangedGETWhenHEADIsRejected(status: Int) async throws {
        let final = url("/media/file.mp3")
        PreflightStubProtocol.register(host: host) { request in
            if request.httpMethod == "HEAD" { return .status(status) }
            return request.url?.path() == "/abs/file" ? .redirect(to: final.absoluteString) : .status(206)
        }
        let request = try download()

        let cleared = try await preflight.check(request)

        #expect(cleared.url == final)
        #expect(cleared.value(forHTTPHeaderField: "Range") == nil)
        let sent = PreflightStubProtocol.requests(host: host)
        #expect(sent.map(\.httpMethod) == ["HEAD", "GET", "GET"])
        #expect(sent.map(\.url) == [url("/file"), url("/file"), final])
        #expect(sent.dropFirst().map { $0.value(forHTTPHeaderField: "Range") } == ["bytes=0-0", "bytes=0-0"])
    }

    @Test func reportsAnUnreachableServer() async throws {
        PreflightStubProtocol.register(host: host) { _ in .fail(.notConnectedToInternet) }

        await #expect(throws: DownloadRedirectPreflightError.unreachable(.notConnectedToInternet)) {
            try await preflight.check(try download())
        }
    }
}
