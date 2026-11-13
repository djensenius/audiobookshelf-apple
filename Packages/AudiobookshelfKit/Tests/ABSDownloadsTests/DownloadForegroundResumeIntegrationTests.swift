import Foundation
import Testing

@testable import ABSDownloads

/// The foreground session's redirect guard with a genuine `URLSession` resume: real resume data
/// from a partial, range-capable response, a resumed `Range` request, and a redirect to another
/// origin (another loopback port) that must not be followed.
struct DownloadForegroundResumeIntegrationTests {
    /// Forwards redirects to the engine's delegate and reports progress and completions.
    private final class Probe: NSObject, URLSessionDownloadDelegate, Sendable {
        let target = DownloadSessionDelegate()
        let wrote: AsyncStream<Void>.Continuation
        let completed: AsyncStream<(task: Int, error: URLError?)>.Continuation

        init(
            wrote: AsyncStream<Void>.Continuation,
            completed: AsyncStream<(task: Int, error: URLError?)>.Continuation
        ) {
            self.wrote = wrote
            self.completed = completed
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo: URL) {}

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            wrote.yield()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            completed.yield((task.taskIdentifier, error as? URLError))
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            await target.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request)
        }
    }

    @Test(.timeLimit(.minutes(1))) func resumedRangeRequestIsNotRedirectedToAnotherOrigin() async throws {
        let offOrigin = try LoopbackHTTPServer { _ in
            Data("HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Length: 3\r\n\r\nbad".utf8)
        }
        try await offOrigin.start()
        defer { offOrigin.stop() }
        let elsewhere = offOrigin.url("/elsewhere.mp3")
        // The first response sends a quarter of the body and stalls, so a cancel yields resume data.
        let origin = try LoopbackHTTPServer { head in
            guard head.httpHeader("Range") == nil else {
                return Data("HTTP/1.1 302 Found\r\nLocation: \(elsewhere)\r\nContent-Length: 0\r\n\r\n".utf8)
            }
            let head =
                "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Length: 1048576\r\n"
                + "Accept-Ranges: bytes\r\nETag: \"v1\"\r\nLast-Modified: Mon, 02 Nov 2026 10:00:00 GMT\r\n\r\n"
            return Data(head.utf8) + Data(repeating: 0x61, count: 262_144)
        }
        try await origin.start()
        defer { origin.stop() }

        let (writes, wrote) = AsyncStream<Void>.makeStream()
        let (completions, completed) = AsyncStream<(task: Int, error: URLError?)>.makeStream()
        let session = URLSession(
            configuration: .ephemeral, delegate: Probe(wrote: wrote, completed: completed), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: origin.url("/abs/api/items/li_1/file/1/download"))
        request.setValue("secret", forHTTPHeaderField: "X-Custom")
        let first = session.downloadTask(with: request)
        first.resume()
        for await _ in writes { break }
        let resumeData = try #require(await first.cancelByProducingResumeData())

        let resumed = session.downloadTask(withResumeData: resumeData)
        resumed.resume()
        var error: URLError?
        for await completion in completions where completion.task == resumed.taskIdentifier {
            error = completion.error
            break
        }

        #expect(origin.requests.count == 2)
        #expect(origin.requests.last?.httpHeader("Range")?.hasPrefix("bytes=") == true)
        #expect(origin.requests.last?.httpHeader("X-Custom") == "secret")
        #expect(error?.code == .cancelled)
        #expect(offOrigin.connections == 0)
        #expect(offOrigin.requests.isEmpty)
    }
}
