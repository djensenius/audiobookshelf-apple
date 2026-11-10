import Foundation
import Testing

@testable import ABSDownloads

/// How a task that ended without a file is classified: the same checks as a body, in the
/// same order, so an empty 401 from another origin or after a redirect never refreshes.
struct DownloadSessionDelegateTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var status: Int
        var answeredBy = DownloadSessionDelegateTests.url.absoluteString
        var contentType = "audio/mpeg"
        var expected: DownloadTaskResult

        var testDescription: String { "\(status) from \(answeredBy) (\(contentType))" }
    }

    static let url = URL(string: "https://abs.example/abs/api/items/li_1/file/1/download")!

    @Test(arguments: [
        Case(status: 401, answeredBy: "https://cdn.other.test/file.mp3", expected: .offOrigin),
        Case(status: 200, answeredBy: "http://abs.example/abs/api/items/li_1/file/1/download", expected: .offOrigin),
        Case(status: 401, answeredBy: "https://abs.example/abs/login", expected: .redirectedUnauthorized),
        Case(status: 401, expected: .httpStatus(401)),
        Case(status: 204, expected: .httpStatus(204)),
        Case(status: 302, expected: .httpStatus(302)),
        Case(status: 200, contentType: "text/html", expected: .unexpectedContent("text/html")),
        Case(status: 200, expected: .failed(DownloadTransferFailure(URLError(.zeroByteResource)))),
        Case(status: 206, expected: .failed(DownloadTransferFailure(URLError(.zeroByteResource)))),
    ])
    func classifiesTaskWithoutFile(_ test: Case) {
        let task = URLSession.shared.downloadTask(with: Self.url)
        let response = HTTPURLResponse(
            url: URL(string: test.answeredBy)!, statusCode: test.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": test.contentType])

        #expect(DownloadSessionDelegate().completion(of: task, response: response, error: nil) == test.expected)
    }

    @Test func taskWithoutResponseIsTransient() {
        let task = URLSession.shared.downloadTask(with: Self.url)

        #expect(DownloadSessionDelegate().completion(of: task, response: nil, error: nil) == .httpStatus(0))
    }

    @Test func errorWinsOverResponse() {
        let task = URLSession.shared.downloadTask(with: Self.url)
        let response = HTTPURLResponse(url: Self.url, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: [:])
        let error = URLError(.networkConnectionLost)

        #expect(
            DownloadSessionDelegate().completion(of: task, response: response, error: error)
                == .failed(DownloadTransferFailure(error)))
    }

    @Test func classifiesSystemCancellations() {
        func failure(_ code: URLError.Code, reason: Int? = nil) -> DownloadTransferFailure {
            var info: [String: Any] = [:]
            info[NSURLErrorBackgroundTaskCancelledReasonKey] = reason
            return DownloadTransferFailure(URLError(code, userInfo: info))
        }
        let forceQuit = failure(.cancelled, reason: NSURLErrorCancelledReasonUserForceQuitApplication)
        let disabled = failure(.cancelled, reason: NSURLErrorCancelledReasonBackgroundUpdatesDisabled)
        let disconnected = failure(.backgroundSessionWasDisconnected)
        let inUse = failure(.backgroundSessionInUseByAnotherProcess)

        #expect(forceQuit.isBackgroundCancellation && forceQuit.isForceQuit)
        #expect(disabled.isBackgroundCancellation && !disabled.isForceQuit)
        #expect(disconnected.isSessionDisconnected && !disconnected.isSessionInUse)
        #expect(inUse.isSessionInUse && !inUse.isSessionDisconnected)
        #expect(!failure(.cancelled).isBackgroundCancellation)
    }

    @Test func declaredLengthIsTheWholeFile() {
        func response(_ status: Int, _ headers: [String: String]) -> HTTPURLResponse? {
            HTTPURLResponse(url: Self.url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        }

        #expect(DownloadSessionDelegate.declaredLength(of: response(200, ["Content-Length": "18"])) == 18)
        #expect(DownloadSessionDelegate.declaredLength(of: response(200, [:])) == nil)
        #expect(
            DownloadSessionDelegate.declaredLength(
                of: response(206, ["Content-Range": "bytes 10-17/18", "Content-Length": "8"])) == 18)
        #expect(DownloadSessionDelegate.declaredLength(of: response(206, ["Content-Range": "bytes 10-17/*"])) == nil)
        #expect(DownloadSessionDelegate.declaredLength(of: response(206, ["Content-Length": "8"])) == nil)
    }
}
