import ABSAPI
import Foundation
import Synchronization

/// What a finished task produced.
enum DownloadTaskResult: Sendable {
    /// The file was moved to the part's destination; `bytes` is its size.
    case moved(bytes: Int64)
    /// The server answered with a status other than 200 or 206; the body was discarded.
    case httpStatus(Int)
    /// A 401 after a redirect: `URLSession` doesn't forward `Authorization` to the new URL, so
    /// a refresh can't help.
    case redirectedUnauthorized
    /// The response came from another origin than the request (a redirect left the server);
    /// the body was discarded.
    case offOrigin
    /// The body was an HTML page (a proxy or captive portal), not the file.
    case unexpectedContent(String)
    /// The body's size isn't the part's expected size.
    case sizeMismatch(expected: Int64, actual: Int64)
    /// The body couldn't be moved to the destination.
    case moveFailed(String, isOutOfSpace: Bool)
    /// The transfer failed or was cancelled.
    case failed(DownloadTransferFailure)
}

struct DownloadTransferFailure: Sendable {
    var message: String
    /// `NSURLSessionDownloadTaskResumeData`, in the clear: seal it before storing it.
    var resumeData: Data?
    /// The system cancelled the transfer for a reason outside it: the user force-quit the
    /// app, background updates are off, or the system was short of resources.
    var isBackgroundCancellation: Bool
    /// The session lost `nsurlsessiond`, or another process holds it: it must be recreated.
    var isSessionLost: Bool
    var isOutOfSpace: Bool

    init(_ error: any Error) {
        let urlError = error as? URLError
        message = error.localizedDescription
        resumeData = urlError?.downloadTaskResumeData
        isBackgroundCancellation = urlError?.backgroundTaskCancelledReason != nil
        isSessionLost =
            urlError?.code == .backgroundSessionWasDisconnected
            || urlError?.code == .backgroundSessionInUseByAnotherProcess
        isOutOfSpace = DownloadLocations.isOutOfSpace(error)
    }
}

enum DownloadSessionEvent: Sendable {
    case progress(URLSessionTask, bytesWritten: Int64, expectedBytes: Int64)
    case completed(URLSessionTask, DownloadTaskResult)
    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)`.
    case backgroundEventsFinished
    /// `urlSession(_:didBecomeInvalidWithError:)`: the session must be created again.
    case sessionInvalidated
    /// Posted by the engine to restart queued parts once the events delivered before it
    /// are handled.
    case restartQueued
    /// Posted by tests: resumed once every earlier event is handled.
    case barrier(CheckedContinuation<Void, Never>)
}

extension URLSessionTask {
    /// The part ID the engine stores in `taskDescription`.
    var partID: UUID? {
        taskDescription.flatMap(UUID.init(uuidString:))
    }
}

/// The background session's delegate. It handles each finished file synchronously (the
/// system deletes it when the callback returns) and forwards everything else, in order, to
/// the engine through ``events``. It outlives sessions: a recreated session gets the same one.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    /// Where a part's file goes, and its size when known.
    struct Target: Sendable {
        var destination: URL
        var expectedBytes: Int64
    }

    let events: AsyncStream<DownloadSessionEvent>
    private let continuation: AsyncStream<DownloadSessionEvent>.Continuation
    private let targets = Mutex<[UUID: Target]>([:])
    private let finished = Mutex<[Int: DownloadTaskResult]>([:])

    override init() {
        (events, continuation) = AsyncStream.makeStream()
        super.init()
    }

    /// Where a finished file for `partID` goes; set before its task can finish.
    func setTarget(_ target: Target?, for partID: UUID) {
        targets.withLock { $0[partID] = target }
    }

    func post(_ event: DownloadSessionEvent) {
        continuation.yield(event)
    }

    /// Checks the response, then moves the file. A body that isn't the file (another origin,
    /// an error status, an HTML page, the wrong size) never reaches the media location.
    func finish(_ task: URLSessionTask, location: URL) -> DownloadTaskResult {
        guard let response = task.response as? HTTPURLResponse else { return .httpStatus(0) }
        guard let requested = task.originalRequest?.url, let answered = response.url,
            DownloadRequests.isSameOrigin(requested, answered)
        else { return .offOrigin }
        if response.statusCode == 401, answered != requested { return .redirectedUnauthorized }
        guard response.statusCode == 200 || response.statusCode == 206 else { return .httpStatus(response.statusCode) }
        if let type = response.mimeType?.lowercased(), type == "text/html" { return .unexpectedContent(type) }
        guard let partID = task.partID, let target = targets.withLock({ $0[partID] }) else {
            return .moveFailed("The download has no destination.", isOutOfSpace: false)
        }
        let size = DownloadLocations.fileSize(at: location) ?? task.countOfBytesReceived
        if target.expectedBytes > 0, size != target.expectedBytes {
            return .sizeMismatch(expected: target.expectedBytes, actual: size)
        }
        do {
            try DownloadLocations.moveFile(at: location, to: target.destination)
        } catch {
            return .moveFailed(error.localizedDescription, isOutOfSpace: DownloadLocations.isOutOfSpace(error))
        }
        return .moved(bytes: DownloadLocations.fileSize(at: target.destination) ?? task.countOfBytesReceived)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        let result = finish(downloadTask, location: location)
        finished.withLock { $0[downloadTask.taskIdentifier] = result }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        continuation.yield(
            .progress(downloadTask, bytesWritten: totalBytesWritten, expectedBytes: totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        // A moved file is kept even if an error follows; otherwise the error wins.
        let result = finished.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        if let result, case .moved = result {
            continuation.yield(.completed(task, result))
        } else if let error {
            continuation.yield(.completed(task, .failed(DownloadTransferFailure(error))))
        } else if let result {
            continuation.yield(.completed(task, result))
        } else {
            // No file and no error: an empty error response, or a body the system dropped.
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            let failed = status == 200 || status == 206
            continuation.yield(
                .completed(
                    task, failed ? .failed(DownloadTransferFailure(URLError(.zeroByteResource))) : .httpStatus(status)))
        }
    }

    /// Only called for non-background sessions: a background session follows redirects
    /// itself, so ``finish(_:location:)`` also rejects responses from another origin.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        DownloadRequests.redirect(following: response, to: request, original: task.originalRequest)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        continuation.yield(.backgroundEventsFinished)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        finished.withLock { $0.removeAll() }
        continuation.yield(.sessionInvalidated)
    }
}
