import Foundation
import Synchronization

@testable import ABSPlayback

/// Serves a body per registered host, honouring `Range` like Express `sendFile`, and records the
/// requests. Hosts are unique, so parallel tests never share a route.
final class StreamStubProtocol: URLProtocol {
    struct Route: Sendable {
        var body = Data()
        var mimeType = "audio/mpeg"
        /// A status other than 200 is sent with no body.
        var status = 200
        /// Answers a `Range` request with `206`; when `false`, always `200` with the whole body
        /// (still sending `Accept-Ranges: bytes`, as Express does behind a proxy that drops `Range`).
        var honorsRange = true
        /// Answers every `Range` request with a `206` from this offset instead of the requested one.
        var rangeStartsAt: Int?
        /// Answers a request for one of these paths with a 302 to its URL instead.
        var redirects: [String: String] = [:]
        /// Sends the body in chunks of this many bytes.
        var chunkSize = Int.max
        /// Sends the response and the first chunk, then nothing more until the load is stopped.
        var holdsAfterFirstChunk = false
        /// Sends only this many bytes of the body it announced, then finishes cleanly.
        var truncatesTo: Int?
        var requests: [URLRequest] = []
        /// How many loads the session stopped (each one does, when it ends or is cancelled).
        var stops = 0
    }

    private static let routes = Mutex<[String: Route]>([:])

    static func register(_ route: Route) -> String {
        let host = "\(UUID().uuidString.lowercased()).stream.test"
        routes.withLock { $0[host] = route }
        return host
    }

    /// Adds redirects to `host`'s route, for one that points back at itself.
    static func register(redirects: [String: String], on host: String) {
        routes.withLock { $0[host]?.redirects.merge(redirects) { $1 } }
    }

    static func requests(_ host: String) -> [URLRequest] {
        routes.withLock { $0[host]?.requests ?? [] }
    }

    static func stops(_ host: String) -> Int {
        routes.withLock { $0[host]?.stops ?? 0 }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamStubProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return routes.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
            let route = Self.routes.withLock({ routes -> Route? in
                routes[host]?.requests.append(request)
                return routes[host]
            })
        else { return client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) ?? () }
        if let location = route.redirects[url.path()], let next = URL(string: location) {
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
            // Like URLSession, propose the original request (and its headers) at the new URL.
            var proposed = request
            proposed.url = next
            client?.urlProtocol(self, wasRedirectedTo: proposed, redirectResponse: response)
            return
        }
        let total = route.body.count
        var status = route.status
        var headers = ["Content-Type": route.mimeType, "Accept-Ranges": "bytes"]
        var body = status == 200 ? route.body : Data()
        if status == 200, route.honorsRange, let range = request.value(forHTTPHeaderField: "Range"),
            let match = range.firstMatch(of: /^bytes=(\d+)-(\d*)$/), let start = Int(match.1), start < total
        {
            let requestedEnd = min(Int(match.2) ?? (total - 1), total - 1)
            // From `rangeStartsAt` when set, through the requested end and at least the requested length.
            let end =
                route.rangeStartsAt.map { min(max(requestedEnd, $0 + requestedEnd - start), total - 1) } ?? requestedEnd
            let start = route.rangeStartsAt ?? start
            status = 206
            headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
            body = route.body.subdata(in: start..<(end + 1))
        }
        headers["Content-Length"] = String(body.count)
        if let truncatesTo = route.truncatesTo { body = body.prefix(truncatesTo) }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < body.count {
            let end = offset + min(route.chunkSize, body.count - offset)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
            offset = end
            if route.holdsAfterFirstChunk { return }
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        guard let host = request.url?.host() else { return }
        Self.routes.withLock { $0[host]?.stops += 1 }
    }
}

/// A ``ResourceLoadingRequest`` that records what the loader gives it.
final class RecordingLoadingRequest: ResourceLoadingRequest, Sendable {
    private struct State {
        var information: ContentInformation?
        var data = Data()
        var finished: (error: (any Error)?, count: Int)?
        var waiter: CheckedContinuation<Void, Never>?
    }

    let requestedRange: RequestedRange?
    let wantsContentInformation: Bool
    private let state = Mutex(State())

    init(range: RequestedRange?, wantsContentInformation: Bool = true) {
        requestedRange = range
        self.wantsContentInformation = wantsContentInformation
    }

    var information: ContentInformation? { state.withLock { $0.information } }
    var data: Data { state.withLock { $0.data } }
    var error: (any Error)? { state.withLock { $0.finished?.error } }
    var finishCount: Int { state.withLock { $0.finished?.count ?? 0 } }

    func fill(_ information: ContentInformation) {
        state.withLock { $0.information = information }
    }

    func respond(with data: Data) {
        state.withLock { $0.data.append(data) }
    }

    func finish(_ error: (any Error)?) {
        let waiter = state.withLock { state in
            state.finished = (state.finished?.error ?? error, (state.finished?.count ?? 0) + 1)
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    /// Returns once the loader finished the request.
    func finished() async {
        await withCheckedContinuation { continuation in
            let done = state.withLock { state in
                if state.finished == nil { state.waiter = continuation }
                return state.finished != nil
            }
            if done { continuation.resume() }
        }
    }
}
