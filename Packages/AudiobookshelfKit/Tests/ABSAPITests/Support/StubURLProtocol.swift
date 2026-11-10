import Foundation
import Synchronization

/// A canned response returned by ``StubURLProtocol``.
struct StubResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
    /// Delays the response so concurrent requests overlap.
    var delay: Duration?
    /// Fails the request with this error instead of responding.
    var error: URLError?
    /// Redirects to this URL (with `status` and a `Location` header) through
    /// `urlProtocol(_:wasRedirectedTo:redirectResponse:)`, so session and task delegates run.
    var redirect: URL?

    static func json(_ json: String, status: Int = 200, delay: Duration? = nil) -> StubResponse {
        StubResponse(
            status: status, headers: ["Content-Type": "application/json"], body: Data(json.utf8), delay: delay)
    }

    static func text(_ text: String, status: Int) -> StubResponse {
        StubResponse(status: status, headers: ["Content-Type": "text/plain"], body: Data(text.utf8))
    }

    static func redirect(to location: String, status: Int = 302) -> StubResponse {
        StubResponse(status: status, headers: ["Location": location], redirect: URL(string: location))
    }

    static func failure(_ code: URLError.Code) -> StubResponse {
        StubResponse(status: 0, error: URLError(code))
    }
}

/// A `URLProtocol` that answers requests for registered hosts with canned responses and
/// records every request it sees, including its body.
///
/// Routes are keyed by host so tests running in parallel never share state; use
/// ``StubServer`` to get a unique host.
final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> StubResponse

    private struct Route {
        var handler: Handler
        var requests: [URLRequest] = []
    }

    private static let routes = Mutex<[String: Route]>([:])
    private let isStopped = Mutex(false)

    static func register(host: String, handler: @escaping Handler) {
        routes.withLock { $0[host] = Route(handler: handler) }
    }

    static func requests(host: String) -> [URLRequest] {
        routes.withLock { $0[host]?.requests ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return routes.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            request.httpBody = Self.read(stream)
        }
        let handler = Self.routes.withLock { routes -> Handler? in
            guard let host = request.url?.host() else { return nil }
            routes[host]?.requests.append(request)
            return routes[host]?.handler
        }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let stub = handler(request)
        if let delay = stub.delay {
            let box = UncheckedProtocol(value: self)
            let recorded = request
            DispatchQueue.global().asyncAfter(deadline: .now() + delay.timeInterval) {
                box.value.deliver(stub, for: recorded)
            }
        } else {
            deliver(stub, for: request)
        }
    }

    override func stopLoading() {
        isStopped.withLock { $0 = true }
    }

    private func deliver(_ stub: StubResponse, for request: URLRequest) {
        guard !isStopped.withLock({ $0 }), let url = request.url else { return }
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard
            let response = HTTPURLResponse(
                url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let location = stub.redirect {
            // Mirrors URLSession: the proposed request keeps every header except Authorization.
            var next = request
            next.url = location
            next.setValue(nil, forHTTPHeaderField: "Authorization")
            if stub.status == 303 {
                next.httpMethod = "GET"
                next.httpBody = nil
            }
            // If the delegate follows the redirect, the session ignores the response below; if
            // it declines, the 3xx response is what the task returns.
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ stream: InputStream) -> Data {
        var data = Data()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A unique stub host with a subpath base URL and a session configuration that routes to it.
///
/// Routes stay registered for the life of the test process; hosts are unique, so they never
/// collide.
struct StubServer: Sendable {
    let host: String

    init(host: String = uniqueHost(), handler: @escaping StubURLProtocol.Handler) {
        self.host = host
        StubURLProtocol.register(host: host, handler: handler)
    }

    static func uniqueHost() -> String {
        "\(UUID().uuidString.lowercased()).stub.test"
    }

    /// `https://<host>/abs`, a server hosted under a subpath.
    var baseURL: URL {
        URL(string: "https://\(host)/abs")!
    }

    var requests: [URLRequest] {
        StubURLProtocol.requests(host: host)
    }

    func requests(path: String) -> [URLRequest] {
        requests.filter { $0.url?.path() == path }
    }

    func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.absConnection()
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }
}

// URLProtocol is not Sendable, but the URL loading system lets a protocol call its client
// from any thread, and the delayed delivery is the only use after `startLoading` returns.
private struct UncheckedProtocol: @unchecked Sendable {
    let value: StubURLProtocol
}

extension Duration {
    fileprivate var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
