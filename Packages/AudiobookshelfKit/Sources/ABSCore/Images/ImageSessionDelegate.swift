import Foundation
import Synchronization

/// The image session's delegate (ADR 0005, "Redirects" and the 4 MiB input cap).
///
/// It writes each response body to a temporary file in the chunks URLSession delivers, ends a
/// load as soon as `Content-Length` or the running count passes the cap, and applies
/// ``RedirectPolicy`` to every hop. Callbacks are routed by task to an ``ImageDownload``.
final class ImageSessionDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private let downloads = Mutex<[Int: ImageDownload]>([:])
    /// This session's folder of temporary downloads, created on demand.
    let temporaryFolder = FileManager.default.temporaryDirectory.appending(
        path: "ImageDownloads-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// Loads `request` on `session`, whose delegate must be `self`, into a temporary file that
    /// the caller owns. Cancelling the calling task cancels the load.
    func download(_ request: URLRequest, session: URLSession) async throws -> (URL, URLResponse) {
        let task = session.dataTask(with: request)
        let download = ImageDownload(original: request, folder: temporaryFolder)
        downloads.withLock { $0[task.taskIdentifier] = download }
        defer { _ = downloads.withLock { $0.removeValue(forKey: task.taskIdentifier) } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if download.start(continuation) { task.resume() }
            }
        } onCancel: {
            download.finish(.failure(CancellationError()))
            task.cancel()
        }
    }

    private func download(for task: URLSessionTask) -> ImageDownload? {
        downloads.withLock { $0[task.taskIdentifier] }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(download(for: dataTask)?.receive(response) == true ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if download(for: dataTask)?.append(data) != true { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        download(for: task)?.complete(error)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        download(for: task)?.redirect(following: response, to: request)
    }
}

/// One image load: its redirect state, its temporary file and the caller's continuation, which
/// is resumed exactly once.
final class ImageDownload: Sendable {
    typealias Outcome = Result<(URL, URLResponse), any Error>

    private struct State {
        var isStripped = false
        var response: URLResponse?
        var file: URL?
        var handle: FileHandle?
        var total = 0
        var continuation: CheckedContinuation<(URL, URLResponse), any Error>?
        var outcome: Outcome?
    }

    private let original: URLRequest
    private let folder: URL
    private let state = Mutex(State())

    init(original: URLRequest, folder: URL = FileManager.default.temporaryDirectory) {
        self.original = original
        self.folder = folder
    }

    /// Stores the caller's continuation; returns `false` (having resumed it) if the load already
    /// ended, i.e. it was cancelled before starting.
    func start(_ continuation: CheckedContinuation<(URL, URLResponse), any Error>) -> Bool {
        let outcome = state.withLock { state in
            if state.outcome == nil { state.continuation = continuation }
            return state.outcome
        }
        guard let outcome else { return true }
        continuation.resume(with: outcome)
        return false
    }

    /// Ends the load once: closes the file (deleting it on failure) and resumes the caller.
    func finish(_ outcome: Outcome) {
        let continuation = state.withLock { state -> CheckedContinuation<(URL, URLResponse), any Error>? in
            guard state.outcome == nil else { return nil }
            try? state.handle?.close()
            state.handle = nil
            if case .failure = outcome, let file = state.file {
                try? FileManager.default.removeItem(at: file)
            }
            state.outcome = outcome
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(with: outcome)
    }

    /// Checks the status and `Content-Length`, and opens the temporary file. Returns whether to
    /// continue.
    func receive(_ response: URLResponse) -> Bool {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        let failure: (any Error)?
        if !(200..<300).contains(status) {
            failure = ImagePipelineError.httpStatus(status)
        } else if response.expectedContentLength > Int64(ImageCacheLimits.maxInputBytes) {
            failure = ImagePipelineError.tooLarge
        } else {
            failure = state.withLock { state -> (any Error)? in
                guard state.outcome == nil else { return CancellationError() }
                // A second response (a multipart body) would orphan the first file.
                guard state.file == nil else { return ImagePipelineError.unsupportedImage }
                let file = folder.appending(path: "image-\(UUID().uuidString).download")
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    state.file = file
                    state.handle = try FileHandle(forWritingTo: file)
                    state.response = response
                    return nil
                } catch {
                    return error
                }
            }
        }
        guard let failure else { return true }
        finish(.failure(failure))
        return false
    }

    /// Writes a chunk. Returns `false`, ending the load, once the body passes the input cap.
    func append(_ data: Data) -> Bool {
        let failure = state.withLock { state -> (any Error)? in
            guard state.outcome == nil, let handle = state.handle else { return CancellationError() }
            state.total += data.count
            guard state.total <= ImageCacheLimits.maxInputBytes else { return ImagePipelineError.tooLarge }
            do {
                try handle.write(contentsOf: data)
                return nil
            } catch {
                return error
            }
        }
        guard let failure else { return true }
        finish(.failure(failure))
        return false
    }

    func complete(_ error: (any Error)?) {
        if let error {
            finish(.failure(error))
            return
        }
        let result = state.withLock { state in state.file.flatMap { file in state.response.map { (file, $0) } } }
        finish(result.map(Outcome.success) ?? .failure(URLError(.badServerResponse)))
    }

    /// The next hop under ``RedirectPolicy``, or `nil` to refuse it. Hops within the request's
    /// origin keep the original headers. Once a hop leaves it, the request is rebuilt with only
    /// `Accept`, and every later hop stays stripped. No hop uses cookies. A hop off the request's
    /// origin must pass ``ImageDestination``: the first request did, so its origin is the
    /// connection's server or a public `https` host, and any other hop must be a public `https`
    /// host, so nothing else on this device or the local network is reachable.
    func redirect(following response: HTTPURLResponse, to request: URLRequest) -> URLRequest? {
        guard let target = request.url, ImageDestination.isAllowed(target, server: original.url) else { return nil }
        let wasStripped = state.withLock { $0.isStripped }
        guard
            let hop = RedirectPolicy.hop(
                following: response, to: request, original: original, wasStripped: wasStripped)
        else { return nil }
        var next = hop.request
        if hop.isStripped {
            state.withLock { $0.isStripped = true }
            next.setValue(original.value(forHTTPHeaderField: "Accept") ?? "image/*", forHTTPHeaderField: "Accept")
        }
        next.cachePolicy = .reloadIgnoringLocalCacheData
        next.httpShouldHandleCookies = false
        return next
    }
}
