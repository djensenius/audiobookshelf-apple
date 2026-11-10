import ABSAPI
import Foundation
import Synchronization

/// What a finished task produced.
enum DownloadTaskResult: Sendable {
    /// The file was moved to the part's destination.
    case moved(bytes: Int64)
    /// The server answered with a non-2xx status; the body was discarded.
    case httpStatus(Int)
    /// The response came from another origin than the request (a redirect left the server);
    /// the body was discarded.
    case offOrigin
    /// The body couldn't be moved to the destination.
    case moveFailed(String)
    /// The transfer failed or was cancelled.
    case failed(DownloadTransferFailure)
}

struct DownloadTransferFailure: Sendable {
    var message: String
    /// `NSURLSessionDownloadTaskResumeData`, in the clear: seal it before storing it.
    var resumeData: Data?
    /// The user force-quit the app, which cancels its background transfers.
    var isForceQuit: Bool

    init(_ error: any Error) {
        let urlError = error as? URLError
        message = error.localizedDescription
        resumeData = urlError?.downloadTaskResumeData
        isForceQuit = urlError?.backgroundTaskCancelledReason == .userForceQuitApplication
    }
}

enum DownloadSessionEvent: Sendable {
    case progress(URLSessionTask, bytesWritten: Int64, expectedBytes: Int64)
    case completed(URLSessionTask, DownloadTaskResult)
    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)`.
    case backgroundEventsFinished
    /// Posted by the engine after reattaching to the session's tasks at launch; it follows
    /// the events the session had already delivered.
    case reattached(candidates: [UUID])
}

extension URLSessionTask {
    /// The part ID the engine stores in `taskDescription`.
    var partID: UUID? {
        taskDescription.flatMap(UUID.init(uuidString:))
    }
}

/// The background session's delegate. It handles each finished file synchronously (the
/// system deletes it when the callback returns) and forwards everything else, in order, to
/// the engine through ``events``.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let events: AsyncStream<DownloadSessionEvent>
    private let continuation: AsyncStream<DownloadSessionEvent>.Continuation
    private let destinations = Mutex<[UUID: URL]>([:])
    private let finished = Mutex<[Int: DownloadTaskResult]>([:])

    override init() {
        (events, continuation) = AsyncStream.makeStream()
        super.init()
    }

    /// Where a finished file for `partID` goes; set before its task can finish.
    func setDestination(_ destination: URL?, for partID: UUID) {
        destinations.withLock { $0[partID] = destination }
    }

    func post(_ event: DownloadSessionEvent) {
        continuation.yield(event)
    }

    /// Checks the response, then moves the file. A non-2xx body or one from another origin
    /// is never moved into the media location.
    func finish(_ task: URLSessionTask, location: URL) -> DownloadTaskResult {
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { return .httpStatus(status) }
        guard let origin = task.originalRequest?.url, let final = task.response?.url,
            DownloadRequests.isSameOrigin(origin, final)
        else { return .offOrigin }
        guard let partID = task.partID, let destination = destinations.withLock({ $0[partID] }) else {
            return .moveFailed("The download has no destination.")
        }
        do {
            return .moved(bytes: try DownloadLocations.moveFile(at: location, to: destination))
        } catch {
            return .moveFailed(error.localizedDescription)
        }
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
        } else {
            continuation.yield(.completed(task, result ?? .failed(DownloadTransferFailure(URLError(.unknown)))))
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
}
