import Foundation
import Synchronization
import Testing

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
        /// One-shot gates by path, and whether each answers the request as it arrives.
        var gates: [String: (gate: StubGate, answersOnArrival: Bool)] = [:]
    }

    private static let routes = Mutex<[String: Route]>([:])

    static func register(host: String, handler: @escaping Handler) {
        routes.withLock { $0[host] = Route(handler: handler) }
    }

    static func useCookieStorage(_ storage: HTTPCookieStorage, host: String) {
        routes.withLock { $0[host]?.cookieStorage = storage }
    }

    /// Holds the next request for `path` on `host` until the gate opens; the handler then answers
    /// it, or, if `answeringOnArrival`, answers it on arrival and the answer is delivered then, so
    /// later requests see what it changed while it's held.
    static func hold(
        host: String, path: String, answeringOnArrival: Bool = false, sourceLocation: SourceLocation = #_sourceLocation
    ) -> StubGate {
        let gate = StubGate(sourceLocation: sourceLocation)
        routes.withLock { $0[host]?.gates[path] = (gate, answeringOnArrival) }
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
        let route = Self.routes.withLock { routes -> (Handler, HTTPCookieStorage?, (StubGate, Bool)?)? in
            guard let host = request.url?.host(), let route = routes[host] else { return nil }
            routes[host]?.requests.append(request)
            let gate = request.url.flatMap { routes[host]?.gates.removeValue(forKey: $0.path()) }
            return (route.handler, route.cookieStorage, gate.map { ($0.gate, $0.answersOnArrival) })
        }
        guard let (handler, cookieStorage, held) = route else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        guard let (gate, answersOnArrival) = held else {
            return respond(to: request, handler: handler, cookieStorage: cookieStorage)
        }
        let answer = answersOnArrival ? handler(request) : nil
        let respondingHandler: Handler
        if let answer {
            respondingHandler = { _ in answer }
        } else {
            respondingHandler = handler
        }
        let box = UncheckedProtocol(value: self)
        gate.hold {
            DispatchQueue.global().async {
                // Cancelling a task cancels its `URLSessionTask` at once, before the gate opens.
                if let task = box.value.task, task.state != .running, let host = request.url?.host() {
                    Self.routes.withLock { $0[host]?.abandoned.append(request) }
                    return
                }
                box.value.respond(to: request, handler: respondingHandler, cookieStorage: cookieStorage)
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
///
/// Bounded, so a gate a test never opens, or a request or call that never arrives, fails the
/// test instead of hanging the run: if, after ``timeout``, the gate isn't open, or someone is
/// still waiting for an arrival, it records an issue, then opens and lets every waiter through.
final class StubGate: Sendable {
    static let timeout: Duration = .seconds(10)

    private struct State {
        var hasArrived = false
        var isOpen = false
        var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
        var held: (@Sendable () -> Void)?
        var watchdog: Task<Void, Never>?

        /// Nothing can wait on the gate any more.
        var isDone: Bool { hasArrived && isOpen }
    }

    private let state = Mutex(State())

    /// - Parameter sourceLocation: Where an issue for a timeout is reported.
    init(sourceLocation: SourceLocation = #_sourceLocation) {
        // Made in the test's task, so a timeout is reported against that test.
        let watchdog = Task { [weak self] in
            do { try await Task.sleep(for: Self.timeout) } catch { return }
            self?.expire(sourceLocation)
        }
        state.withLock { $0.watchdog = watchdog }
    }

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
            defer {
                state.held = nil
                if state.isDone { state.watchdog?.cancel() }
            }
            return state.held
        }
        held?()
    }

    /// Holds `respond` until the gate opens, or calls it now if it's open.
    func hold(_ respond: @escaping @Sendable () -> Void) {
        let (waiters, isOpen) = state.withLock { state in
            state.hasArrived = true
            if !state.isOpen { state.held = respond }
            defer {
                state.arrivalWaiters = []
                if state.isDone { state.watchdog?.cancel() }
            }
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

    private func expire(_ sourceLocation: SourceLocation) {
        let (waiters, held, wasOpen) = state.withLock { state in
            defer {
                state.hasArrived = true
                state.isOpen = true
                state.arrivalWaiters = []
                state.held = nil
            }
            return (state.arrivalWaiters, state.held, state.isOpen)
        }
        guard !wasOpen || !waiters.isEmpty else { return }
        Issue.record(
            "A gate wasn't opened, or what it holds didn't arrive, within \(Self.timeout)",
            sourceLocation: sourceLocation)
        waiters.forEach { $0.resume() }
        held?()
    }
}

// URLProtocol is not Sendable, but the URL loading system lets a protocol call its client from
// any thread, and a held request is the only use after `startLoading` returns.
private struct UncheckedProtocol: @unchecked Sendable {
    let value: StubURLProtocol
}
