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
/// waits on real time; a request can instead be held by a ``StubGate`` until the test opens it.
/// URLSession doesn't handle cookies for custom protocols, so `Set-Cookie` headers are stored in
/// the jar registered for the host, if any.
final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> StubResponse

    private struct Route {
        var handler: Handler
        var requests: [URLRequest] = []
        /// Held requests the client cancelled before the gate opened.
        var abandoned: [URLRequest] = []
        var cookieStorage: HTTPCookieStorage?
        /// One-shot gates by path.
        var gates: [String: StubGate] = [:]
    }

    private static let routes = Mutex<[String: Route]>([:])

    static func register(host: String, handler: @escaping Handler) {
        routes.withLock { $0[host] = Route(handler: handler) }
    }

    static func useCookieStorage(_ storage: HTTPCookieStorage, host: String) {
        routes.withLock { $0[host]?.cookieStorage = storage }
    }

    /// Holds the next request for `path` on `host` until the gate opens; the handler then answers
    /// it.
    static func hold(host: String, path: String) -> StubGate {
        let gate = StubGate()
        routes.withLock { $0[host]?.gates[path] = gate }
        return gate
    }

    static func requests(host: String) -> [URLRequest] {
        routes.withLock { $0[host]?.requests ?? [] }
    }

    /// Held requests that were cancelled before their gate opened, so they were never answered.
    static func abandonedRequests(host: String) -> [URLRequest] {
        routes.withLock { $0[host]?.abandoned ?? [] }
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
        let route = Self.routes.withLock { routes -> (Handler, HTTPCookieStorage?, StubGate?)? in
            guard let host = request.url?.host(), let route = routes[host] else { return nil }
            routes[host]?.requests.append(request)
            let gate = request.url.flatMap { routes[host]?.gates.removeValue(forKey: $0.path()) }
            return (route.handler, route.cookieStorage, gate)
        }
        guard let (handler, cookieStorage, gate) = route else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        guard let gate else { return respond(to: request, handler: handler, cookieStorage: cookieStorage) }
        let box = UncheckedProtocol(value: self)
        gate.hold {
            DispatchQueue.global().async {
                // Cancelling a task cancels its `URLSessionTask` at once, before the gate opens.
                if let task = box.value.task, task.state != .running, let host = request.url?.host() {
                    Self.routes.withLock { $0[host]?.abandoned.append(request) }
                    return
                }
                box.value.respond(to: request, handler: handler, cookieStorage: cookieStorage)
            }
        }
    }

    private func respond(to request: URLRequest, handler: Handler, cookieStorage: HTTPCookieStorage?) {
        guard let url = request.url else {
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

/// Holds one request, or one call at a test hook, until the test opens it.
final class StubGate: Sendable {
    private struct State {
        var hasArrived = false
        var isOpen = false
        var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
        var held: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    /// Returns once the request has arrived and is being held.
    func arrived() async {
        await withCheckedContinuation { continuation in
            let hasArrived = state.withLock { state in
                if !state.hasArrived { state.arrivalWaiters.append(continuation) }
                return state.hasArrived
            }
            if hasArrived { continuation.resume() }
        }
    }

    /// Lets the request through, now or when it arrives.
    func open() {
        let held = state.withLock { state in
            state.isOpen = true
            defer { state.held = nil }
            return state.held
        }
        held?()
    }

    fileprivate func hold(_ respond: @escaping @Sendable () -> Void) {
        let (waiters, isOpen) = state.withLock { state in
            state.hasArrived = true
            if !state.isOpen { state.held = respond }
            defer { state.arrivalWaiters = [] }
            return (state.arrivalWaiters, state.isOpen)
        }
        waiters.forEach { $0.resume() }
        if isOpen { respond() }
    }

    /// Suspends until the gate opens, for holding a call at a test hook rather than a request.
    func pass() async {
        await withCheckedContinuation { continuation in hold { continuation.resume() } }
    }

    /// Opens the gate and marks it arrived, for a checkpoint in synchronous code, such as a clock
    /// reading, that mustn't wait.
    func reach() {
        open()
        hold {}
    }
}

// URLProtocol is not Sendable, but the URL loading system lets a protocol call its client from
// any thread, and a held request is the only use after `startLoading` returns.
private struct UncheckedProtocol: @unchecked Sendable {
    let value: StubURLProtocol
}
