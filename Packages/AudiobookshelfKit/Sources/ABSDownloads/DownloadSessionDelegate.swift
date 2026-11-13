import ABSAPI
import Foundation
import Synchronization

/// What a finished task produced.
enum DownloadTaskResult: Sendable, Equatable {
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
    /// The body was an error page or message (HTML from a proxy or captive portal, text, JSON
    /// or XML), not the file.
    case unexpectedContent(String)
    /// The body isn't the whole file. `expected` is the size it was checked against: after a
    /// 206, the `Content-Range` total; otherwise the planned size, or else the declared length.
    /// It is `0` when that isn't known.
    case sizeMismatch(expected: Int64, actual: Int64)
    /// The body, or the length the server declared, is over the part's limit; the body was
    /// discarded.
    case tooLarge(limit: Int64)
    /// The body couldn't be moved to the destination.
    case moveFailed(String, isOutOfSpace: Bool)
    /// The transfer failed or was cancelled.
    case failed(DownloadTransferFailure)
}

struct DownloadTransferFailure: Sendable, Equatable {
    var message: String
    /// `NSURLSessionDownloadTaskResumeData`, in the clear: seal it before storing it.
    var resumeData: Data?
    /// The system cancelled the transfer for a reason outside it: the user force-quit the
    /// app, background updates are off, or the system was short of resources.
    var isBackgroundCancellation: Bool
    /// The user force-quit the app; reported once the app creates the session again.
    var isForceQuit: Bool
    /// The session lost `nsurlsessiond` and must be created again.
    var isSessionDisconnected: Bool
    /// Another process holds the session identifier.
    var isSessionInUse: Bool
    var isOutOfSpace: Bool

    init(_ error: any Error) {
        let urlError = error as? URLError
        message = error.localizedDescription
        resumeData = urlError?.downloadTaskResumeData
        isBackgroundCancellation = urlError?.backgroundTaskCancelledReason != nil
        isForceQuit = urlError?.backgroundTaskCancelledReason == .userForceQuitApplication
        isSessionDisconnected = urlError?.code == .backgroundSessionWasDisconnected
        isSessionInUse = urlError?.code == .backgroundSessionInUseByAnotherProcess
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
    /// The `taskDescription` prefix of a task in the engine's foreground session (#467).
    static let foregroundPrefix = "foreground:"

    /// The part ID the engine stores in `taskDescription`, after ``foregroundPrefix`` for a
    /// foreground task.
    var partID: UUID? {
        guard let description = taskDescription else { return nil }
        return UUID(uuidString: isForeground ? String(description.dropFirst(Self.foregroundPrefix.count)) : description)
    }

    /// Whether the task belongs to the engine's foreground session.
    var isForeground: Bool {
        taskDescription?.hasPrefix(Self.foregroundPrefix) == true
    }

    /// The task's identifier among both of the engine's sessions: each session numbers its
    /// tasks from 1, so a foreground task's is made negative.
    var key: Int {
        isForeground ? ~taskIdentifier : taskIdentifier
    }
}

/// The delegate of the engine's sessions, background and foreground. It handles each finished file synchronously (the
/// system deletes it when the callback returns) and forwards everything else, in order, to
/// the engine through ``events``. It outlives sessions: a recreated session gets the same one.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    /// Where a part's file goes, its size when known, and the most it may have.
    struct Target: Sendable {
        var destination: URL
        var expectedBytes: Int64
        var maxBytes: Int64? = nil
    }

    let events: AsyncStream<DownloadSessionEvent>
    private let continuation: AsyncStream<DownloadSessionEvent>.Continuation
    private let targets = Mutex<[UUID: Target]>([:])
    private let finished = Mutex<[Int: DownloadTaskResult]>([:])
    /// The tasks whose redirect off their origin was refused, by ``URLSessionTask/key``.
    private let refusedRedirects = Mutex<Set<Int>>([])

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

    /// Why `response` isn't the part's file, or `nil` when it may be. Checked in this order,
    /// both for a body and for a task that ended without one: another origin than the request
    /// (whatever the status, so no refresh follows), a 401 after a redirect, a status other
    /// than 200 or 206 (ADR 0007: a 204 is an error), and an error body (``isErrorBody(_:)``),
    /// which the size check can't catch when its length happens to match.
    static func classify(response: URLResponse?, task: URLSessionTask) -> DownloadTaskResult? {
        guard let response = response as? HTTPURLResponse else { return .httpStatus(0) }
        guard let requested = task.originalRequest?.url, let answered = response.url,
            DownloadRequests.isSameOrigin(requested, answered)
        else { return .offOrigin }
        if response.statusCode == 401, answered != requested { return .redirectedUnauthorized }
        guard response.statusCode == 200 || response.statusCode == 206 else { return .httpStatus(response.statusCode) }
        if let type = response.mimeType?.lowercased(), isErrorBody(type) { return .unexpectedContent(type) }
        return nil
    }

    /// Whether a body of MIME type `type` is an error page or message rather than a file: any
    /// `text/*`, and JSON or XML (`application/json`, `application/xml`, and `application/*+json`
    /// or `+xml` such as `application/problem+json`). No part (audio, video, an ebook or an
    /// image) has one of these types.
    static func isErrorBody(_ type: String) -> Bool {
        if type.hasPrefix("text/") { return true }
        guard type.hasPrefix("application/") else { return false }
        return type == "application/json" || type == "application/xml" || type.hasSuffix("+json")
            || type.hasSuffix("+xml")
    }

    /// The whole file's length as the response declares it: the total of a 206's
    /// `Content-Range`, or a 200's `Content-Length`.
    static func declaredLength(of response: URLResponse?) -> Int64? {
        guard let response = response as? HTTPURLResponse else { return nil }
        if response.statusCode == 206 {
            return response.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap {
                Int64($0)
            }
        }
        return response.expectedContentLength > 0 ? response.expectedContentLength : nil
    }

    /// Checks the response, then moves the file. A body that isn't the file (see
    /// ``classify(response:task:)``, empty, or the wrong size) never reaches the media
    /// location, nor does one over the target's `maxBytes`.
    ///
    /// The file must have the length the server declared, or for a 200 the planned size (the
    /// file changed since the download was planned, or the server compressed it). After a 206
    /// it must be the whole file the `Content-Range` describes: a resumed task's range starts
    /// where its resume data ends, and the moved file holds both. A 200 with no declared
    /// length for a part of unknown size is accepted when it isn't empty.
    func finish(_ task: URLSessionTask, location: URL) -> DownloadTaskResult {
        if let rejected = Self.classify(response: task.response, task: task) { return rejected }
        guard let partID = task.partID, let target = targets.withLock({ $0[partID] }) else {
            return .moveFailed("The download has no destination.", isOutOfSpace: false)
        }
        let size = DownloadLocations.fileSize(at: location) ?? task.countOfBytesReceived
        guard size > 0 else { return .failed(DownloadTransferFailure(URLError(.zeroByteResource))) }
        let declared = Self.declaredLength(of: task.response)
        if let limit = target.maxBytes, size > limit || (declared ?? 0) > limit { return .tooLarge(limit: limit) }
        let planned = target.expectedBytes > 0 ? target.expectedBytes : nil
        if (task.response as? HTTPURLResponse)?.statusCode == 206 {
            guard size == declared else { return .sizeMismatch(expected: declared ?? 0, actual: size) }
        } else if size != declared, size != planned, declared != nil || planned != nil {
            return .sizeMismatch(expected: planned ?? declared ?? 0, actual: size)
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
        finished.withLock { $0[downloadTask.key] = result }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        continuation.yield(
            .progress(downloadTask, bytesWritten: totalBytesWritten, expectedBytes: totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        continuation.yield(.completed(task, completion(of: task, response: task.response, error: error)))
    }

    /// What `task` produced: a moved file, even if an error follows; otherwise the error, then
    /// what ``finish(_:location:)`` decided. A task that ended with neither (an empty error
    /// response, or a body the system dropped) is classified by its response like a body.
    func completion(of task: URLSessionTask, response: URLResponse?, error: (any Error)?) -> DownloadTaskResult {
        // Cancelled by the refusal, so the error is the cancellation's.
        if refusedRedirects.withLock({ $0.remove(task.key) }) != nil {
            finished.withLock { _ = $0.removeValue(forKey: task.key) }
            return .offOrigin
        }
        let result = finished.withLock { $0.removeValue(forKey: task.key) }
        if let result, case .moved = result { return result }
        if let error { return .failed(DownloadTransferFailure(error)) }
        if let result { return result }
        return Self.classify(response: response, task: task)
            ?? .failed(DownloadTransferFailure(URLError(.zeroByteResource)))
    }

    /// Only called for non-background sessions, such as the foreground session of servers with
    /// custom headers (#467): a background session follows redirects itself, so
    /// ``finish(_:location:)`` also rejects responses from another origin. A hop off the
    /// origin of the task's original request (the fresh request, or the one in its resume data
    /// for a `Range` resume) is refused before anything is sent there, and the task is
    /// cancelled, so it ends with ``DownloadTaskResult/offOrigin`` rather than the redirect's
    /// body.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        if let hop = DownloadRequests.redirect(following: response, to: request, original: task.originalRequest) {
            return hop
        }
        refusedRedirects.withLock { _ = $0.insert(task.key) }
        task.cancel()
        return nil
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        continuation.yield(.backgroundEventsFinished)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        // Only the background session is invalidated; the foreground one lives as long as the
        // engine.
        finished.withLock { $0 = $0.filter { $0.key < 0 } }
        refusedRedirects.withLock { $0 = $0.filter { $0 < 0 } }
        continuation.yield(.sessionInvalidated)
    }
}
