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

    static func json(_ json: String, status: Int = 200, delay: Duration? = nil) -> StubResponse {
        StubResponse(
            status: status, headers: ["Content-Type": "application/json"], body: Data(json.utf8), delay: delay)
    }

    static func text(_ text: String, status: Int) -> StubResponse {
        StubResponse(status: status, headers: ["Content-Type": "text/plain"], body: Data(text.utf8))
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
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let stub = handler(request)
        if let delay = stub.delay {
            let box = UncheckedProtocol(value: self)
            DispatchQueue.global().asyncAfter(deadline: .now() + delay.timeInterval) {
                box.value.deliver(stub, for: url)
            }
        } else {
            deliver(stub, for: url)
        }
    }

    override func stopLoading() {}

    private func deliver(_ stub: StubResponse, for url: URL) {
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
    let host = "\(UUID().uuidString.lowercased()).stub.test"

    init(handler: @escaping StubURLProtocol.Handler) {
        StubURLProtocol.register(host: host, handler: handler)
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
