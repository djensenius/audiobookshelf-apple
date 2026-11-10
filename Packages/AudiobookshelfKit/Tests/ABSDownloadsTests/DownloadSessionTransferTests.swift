import Foundation
import Testing

@testable import ABSDownloads

/// Real transfers through ``StubDownloadSession``: what the delegate does with each body. A
/// body that isn't the part's file never reaches the destination.
@Suite(.timeLimit(.minutes(1))) struct DownloadSessionTransferTests {
    struct Outcome {
        var result: DownloadTaskResult?
        /// The destination's contents, or `nil` if nothing was moved there.
        var moved: Data?
    }

    /// Runs one task answered with `reply` for a part of `expectedBytes`; the suite's time
    /// limit bounds the wait.
    private func transfer(_ reply: StubReply, expectedBytes: Int64 = 11) async -> Outcome {
        let host = "\(UUID().uuidString.lowercased()).stub.test"
        let root = FileManager.default.temporaryDirectory.appending(path: "session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "li_1/1.mp3")
        StubDownloadProtocol.register(host: host) { _ in reply }
        let delegate = DownloadSessionDelegate()
        let session = StubDownloadSession(delegate: delegate)
        defer { session.finishTasksAndInvalidate() }
        let partID = UUID()
        delegate.setTarget(.init(destination: destination, expectedBytes: expectedBytes), for: partID)
        let task = session.downloadTask(
            with: URLRequest(url: URL(string: "https://\(host)/abs/api/items/li_1/file/1/download")!))
        task.taskDescription = partID.uuidString
        task.resume()

        var result: DownloadTaskResult?
        for await event in delegate.events {
            if case .completed(_, let completed) = event {
                result = completed
                break
            }
        }
        return Outcome(result: result, moved: try? Data(contentsOf: destination))
    }

    @Test func movesTheFile() async {
        let outcome = await transfer(.status(200))

        #expect(outcome.result == .moved(bytes: 11))
        #expect(outcome.moved == Data("audio-bytes".utf8))
    }

    /// An error body whose length happens to match the expected size.
    @Test(arguments: ["text/plain", "text/html", "application/json", "application/problem+json"])
    func rejectsErrorBodiesOfTheExpectedSize(contentType: String) async {
        let outcome = await transfer(.status(200, body: Data(#"{"error":1}"#.utf8), contentType: contentType))

        #expect(outcome.result == .unexpectedContent(contentType))
        #expect(outcome.moved == nil)
    }

    @Test func rejectsTheWrongSize() async {
        let outcome = await transfer(.status(200, headers: ["Content-Length": ""]), expectedBytes: 20)

        #expect(outcome.result == .sizeMismatch(expected: 20, actual: 11))
        #expect(outcome.moved == nil)
    }

    /// The file changed on the server since the download was planned.
    @Test func acceptsTheDeclaredLength() async {
        let outcome = await transfer(.status(200), expectedBytes: 20)

        #expect(outcome.result == .moved(bytes: 11))
        #expect(outcome.moved == Data("audio-bytes".utf8))
    }

    @Test func rejectsABodyFromAnotherOrigin() async {
        let outcome = await transfer(.status(200, from: URL(string: "https://cdn.other.test/1.mp3")!))

        #expect(outcome.result == .offOrigin)
        #expect(outcome.moved == nil)
    }

    @Test func keepsResumeDataFromAFailure() async {
        let outcome = await transfer(.failure(resumeData: Data("resume".utf8), partialBody: Data("audio".utf8)))

        guard case .failed(let failure) = outcome.result else {
            Issue.record("Expected a failure, got \(String(describing: outcome.result))")
            return
        }
        #expect(failure.resumeData == Data("resume".utf8))
        #expect(!failure.isBackgroundCancellation)
        #expect(outcome.moved == nil)
    }
}
