import Foundation
import Synchronization

@testable import ABSDownloads

/// Holds stub replies back until the test opens it.
final class StubGate: Sendable {
    private let state = Mutex<(isOpen: Bool, pending: [@Sendable () -> Void])>((false, []))

    func open() {
        let pending = state.withLock { state in
            state.isOpen = true
            defer { state.pending = [] }
            return state.pending
        }
        for action in pending {
            action()
        }
    }

    func run(_ action: @escaping @Sendable () -> Void) {
        let runsNow = state.withLock { state in
            if !state.isOpen { state.pending.append(action) }
            return state.isOpen
        }
        if runsNow { action() }
    }
}

/// How ``StubDownloadProtocol`` answers one request.
enum StubReply: Sendable {
    /// Responds with `status` and `body`, from `from` (the request's URL by default), once
    /// `gate` (if any) opens. `headers` replace the default `Content-Type` and
    /// `Content-Length`; an empty value removes a header.
    case status(
        Int, body: Data = Data("audio-bytes".utf8), contentType: String = "audio/mpeg",
        headers: [String: String] = [:], from: URL? = nil, gate: StubGate? = nil)
    /// Responds 200, sends `partialBody`, then fails with `code` and this resume data and
    /// background cancellation reason, once `gate` (if any) opens.
    case failure(
        code: Int = NSURLErrorNetworkConnectionLost, resumeData: Data? = nil, cancelReason: Int? = nil,
        partialBody: Data? = nil, gate: StubGate? = nil)
    /// Responds `302` to `url`. Like `URLSession`, the proposed request keeps the original's
    /// headers, `Authorization` aside, whatever its origin.
    case redirect(to: URL)

    var gate: StubGate? {
        switch self {
        case .status(_, _, _, _, _, let gate), .failure(_, _, _, _, let gate): gate
        case .redirect: nil
        }
    }
}

/// A `URLProtocol` that answers requests for registered hosts and records them. Routes are
/// keyed by a unique host, so parallel tests never share state.
final class StubDownloadProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> StubReply

    private static let routes = Mutex<[String: (handler: Handler, requests: [URLRequest])]>([:])
    private let isStopped = Mutex(false)

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

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return }
        let request = request
        guard
            let handler = Self.routes.withLock({ routes -> Handler? in
                routes[host]?.requests.append(request)
                return routes[host]?.handler
            })
        else { return }
        let reply = handler(request)
        if let gate = reply.gate {
            let box = UncheckedProtocol(value: self)
            gate.run { box.value.deliver(reply, url: url) }
        } else {
            deliver(reply, url: url)
        }
    }

    override func stopLoading() {
        isStopped.withLock { $0 = true }
    }

    private func deliver(_ reply: StubReply, url: URL) {
        guard !isStopped.withLock({ $0 }), let client else { return }
        switch reply {
        case .status(let status, let body, let contentType, let headers, let from, _):
            var fields = ["Content-Type": contentType, "Content-Length": "\(body.count)"]
            for (name, value) in headers {
                fields[name] = value.isEmpty ? nil : value
            }
            let response = HTTPURLResponse(
                url: from ?? url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self)
        case .failure(let code, let resumeData, let cancelReason, let partialBody, _):
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "audio/mpeg"])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let partialBody { client.urlProtocol(self, didLoad: partialBody) }
            var info: [String: Any] = [:]
            info[NSURLSessionDownloadTaskResumeData] = resumeData
            info[NSURLErrorBackgroundTaskCancelledReasonKey] = cancelReason
            client.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: code, userInfo: info))
        case .redirect(let target):
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            var proposed = URLRequest(url: target)
            for (name, value) in request.allHTTPHeaderFields ?? [:] where name != "Authorization" {
                proposed.setValue(value, forHTTPHeaderField: name)
            }
            client.urlProtocol(self, wasRedirectedTo: proposed, redirectResponse: response)
        }
    }
}

// URLProtocol is not Sendable, but the URL loading system lets a protocol call its client
// from any thread, and the gated delivery is the only use after `startLoading` returns.
private struct UncheckedProtocol: @unchecked Sendable {
    let value: StubDownloadProtocol
}

extension URLRequest {
    /// How many requests the stub has seen for this request's host, including this one.
    var stubCount: Int {
        StubDownloadProtocol.requests(host: url?.host() ?? "").count
    }

    var authorization: String? {
        value(forHTTPHeaderField: "Authorization")
    }
}

/// Forwards to the engine's delegate, then reports each task's completion, so a test can
/// wait for transfers that end without an update.
private final class SignallingDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let target: DownloadSessionDelegate
    let completed: @Sendable ((any Error)?) -> Void

    init(target: DownloadSessionDelegate, completed: @escaping @Sendable ((any Error)?) -> Void) {
        self.target = target
        self.completed = completed
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        target.urlSession(session, downloadTask: downloadTask, didFinishDownloadingTo: location)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        target.urlSession(
            session, downloadTask: downloadTask, didWriteData: bytesWritten, totalBytesWritten: totalBytesWritten,
            totalBytesExpectedToWrite: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        target.urlSession(session, task: task, didCompleteWithError: error)
        completed(error)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        await target.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        target.urlSession(session, didBecomeInvalidWithError: error)
    }
}

/// A ``DownloadSession`` over an ephemeral session with ``StubDownloadProtocol``. Resume data
/// can't be replayed by a stub, so a resumed task repeats the last fresh request, and the
/// resume data is recorded.
final class StubDownloadSession: DownloadSession {
    let session: URLSession
    private let delegate: DownloadSessionDelegate?
    private let state = Mutex<(lastRequest: URLRequest?, resumed: [Data])>((nil, []))

    /// - Parameter completed: called after the delegate has handled each task's completion,
    ///   with its error.
    init(delegate: any URLSessionDelegate, completed: @escaping @Sendable ((any Error)?) -> Void = { _ in }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubDownloadProtocol.self]
        let target = delegate as? DownloadSessionDelegate
        self.delegate = target
        session = URLSession(
            configuration: configuration,
            delegate: target.map { SignallingDelegate(target: $0, completed: completed) } ?? delegate,
            delegateQueue: nil)
    }

    var resumedData: [Data] { state.withLock { $0.resumed } }

    /// Tasks left behind by a "previous launch", already running.
    let leftovers = Mutex<[URLSessionDownloadTask]>([])

    func leaveTask(_ request: URLRequest, description: String) {
        let task = session.downloadTask(with: request)
        task.taskDescription = description
        task.resume()
        leftovers.withLock { $0.append(task) }
    }

    /// What the system does once it has delivered a background wake's events.
    func finishBackgroundEvents() {
        delegate?.urlSessionDidFinishEvents(forBackgroundURLSession: session)
    }

    func downloadTask(with request: URLRequest) -> URLSessionDownloadTask {
        state.withLock { $0.lastRequest = request }
        return session.downloadTask(with: request)
    }

    func downloadTask(withResumeData resumeData: Data) -> URLSessionDownloadTask {
        let request = state.withLock { state in
            state.resumed.append(resumeData)
            return state.lastRequest
        }
        return session.downloadTask(with: request!)
    }

    var allTasks: [URLSessionTask] {
        get async { await session.allTasks }
    }

    func finishTasksAndInvalidate() {
        session.finishTasksAndInvalidate()
    }
}
