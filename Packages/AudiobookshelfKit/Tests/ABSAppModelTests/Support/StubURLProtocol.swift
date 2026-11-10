import Foundation
import Synchronization

/// A canned response returned by ``StubURLProtocol``.
struct StubResponse: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()
    /// Fails the request with this error instead of responding.
    var error: URLError.Code?

    static func json(_ json: String, status: Int = 200, headers: [String: String] = [:]) -> StubResponse {
        StubResponse(
            status: status, headers: headers.merging(["Content-Type": "application/json"]) { $1 }, body: Data(json.utf8)
        )
    }

    static func failure(_ code: URLError.Code) -> StubResponse {
        StubResponse(status: 0, error: code)
    }
}

/// A `URLProtocol` that answers requests for registered hosts with canned responses and records
/// them. Responses are delivered at once and a 3xx is delivered as is, never followed, so nothing
/// waits on real time. URLSession doesn't handle cookies for custom protocols, so `Set-Cookie`
/// headers are stored in the jar registered for the host, if any.
final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> StubResponse

    private struct Route {
        var handler: Handler
        var requests: [URLRequest] = []
        var cookieStorage: HTTPCookieStorage?
    }

    private static let routes = Mutex<[String: Route]>([:])

    static func register(host: String, handler: @escaping Handler) {
        routes.withLock { $0[host] = Route(handler: handler) }
    }

    static func useCookieStorage(_ storage: HTTPCookieStorage, host: String) {
        routes.withLock { $0[host]?.cookieStorage = storage }
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
        let request = request
        let route = Self.routes.withLock { routes -> (Handler, HTTPCookieStorage?)? in
            guard let host = request.url?.host(), let route = routes[host] else { return nil }
            routes[host]?.requests.append(request)
            return (route.handler, route.cookieStorage)
        }
        guard let (handler, cookieStorage) = route, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let stub = handler(request)
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: URLError(error))
            return
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: stub.headers, for: url) {
            cookieStorage?.setCookie(cookie)
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

    override func stopLoading() {}

    /// A configuration that routes every registered host to this protocol.
    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.absConnection()
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }
}
