import AVFoundation
import Foundation
import Testing

@testable import ABSPlayback

struct PlaybackFailureTests {
    private func avError(_ code: AVError.Code, underlying: NSError? = nil) -> NSError {
        NSError(
            domain: AVFoundationErrorDomain, code: code.rawValue,
            userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:])
    }

    private func urlError(_ code: URLError.Code) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code.rawValue)
    }

    @Test func keepsDomainCodeAndUnderlyingError() {
        let failure = PlaybackFailure(error: avError(.unknown, underlying: urlError(.notConnectedToInternet)))

        #expect(failure.kind == .network)
        #expect(failure.domain == AVFoundationErrorDomain)
        #expect(failure.code == AVError.Code.unknown.rawValue)
        #expect(failure.underlyingDomain == NSURLErrorDomain)
        #expect(failure.underlyingCode == URLError.Code.notConnectedToInternet.rawValue)
        #expect(failure.httpStatus == nil)
        #expect(!failure.description.isEmpty)
    }

    @Test func findsNetworkLossDeeperInTheChain() {
        let osStatus = NSError(
            domain: NSOSStatusErrorDomain, code: -12_660, userInfo: [NSUnderlyingErrorKey: urlError(.timedOut)])
        let failure = PlaybackFailure(error: avError(.unknown, underlying: osStatus))

        #expect(failure.kind == .network)
        #expect(failure.underlyingDomain == NSOSStatusErrorDomain)
    }

    @Test func readsHTTPStatusFromTheErrorLog() {
        let error = NSError(domain: "CoreMediaErrorDomain", code: -12_938)
        let fromComment = PlaybackFailure(
            error: error,
            errorLog: [.init(domain: "CoreMediaErrorDomain", statusCode: -12_938, comment: "HTTP 404: File Not Found")])
        #expect(fromComment.kind == .http(status: 404))
        #expect(fromComment.httpStatus == 404)
        #expect(fromComment.domain == "CoreMediaErrorDomain")
        #expect(fromComment.code == -12_938)

        let fromStatus = PlaybackFailure(
            error: error,
            errorLog: [
                .init(domain: "CoreMediaErrorDomain", statusCode: 401, comment: nil),
                .init(domain: "CoreMediaErrorDomain", statusCode: 503, comment: nil),
            ])
        #expect(fromStatus.kind == .http(status: 503))

        let withoutError = PlaybackFailure(
            error: nil, errorLog: [.init(domain: "CoreMediaErrorDomain", statusCode: 403, comment: nil)])
        #expect(withoutError.kind == .http(status: 403))
    }

    @Test func networkLossWinsOverAnHTTPStatus() {
        let failure = PlaybackFailure(
            error: avError(.unknown, underlying: urlError(.networkConnectionLost)),
            errorLog: [.init(domain: "CoreMediaErrorDomain", statusCode: 404, comment: nil)])

        #expect(failure.kind == .network)
        #expect(failure.httpStatus == 404)
    }

    @Test func classifiesTransportErrors() {
        #expect(PlaybackFailure(error: urlError(.secureConnectionFailed)).kind == .tls)
        #expect(PlaybackFailure(error: urlError(.serverCertificateUntrusted)).kind == .tls)
        #expect(PlaybackFailure(error: urlError(.cancelled)).kind == .cancelled)
        #expect(
            PlaybackFailure(
                error: NSError(domain: "CoreMediaErrorDomain", code: -1),
                errorLog: [.init(domain: NSURLErrorDomain, statusCode: URLError.Code.cannotFindHost.rawValue)]
            ).kind == .network)
    }

    @Test func classifiesMediaErrors() {
        #expect(PlaybackFailure(error: avError(.decodeFailed)).kind == .decode)
        #expect(PlaybackFailure(error: avError(.unknown, underlying: avError(.failedToParse))).kind == .decode)
        #expect(PlaybackFailure(error: avError(.fileFormatNotRecognized)).kind == .unsupported)
        #expect(PlaybackFailure(error: avError(.decoderNotFound)).kind == .unsupported)
    }

    @Test func unknownWithoutDetails() {
        let failure = PlaybackFailure(error: nil)

        #expect(failure.kind == .unknown)
        #expect(failure.domain.isEmpty)
        #expect(failure.description == "Unknown error")
        #expect(PlaybackFailure(error: NSError(domain: "Other", code: 1)).kind == .unknown)
    }
}
