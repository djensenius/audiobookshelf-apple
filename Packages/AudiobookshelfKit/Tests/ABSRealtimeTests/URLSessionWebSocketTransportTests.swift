import Foundation
import Testing

@testable import ABSRealtime

@Suite(.timeLimit(.minutes(1)))
struct URLSessionWebSocketTransportTests {
    @Test func isolatedTransportsDoNotShareCookies() throws {
        let first = URLSessionWebSocketTransport.isolated()
        let second = URLSessionWebSocketTransport.isolated()
        let firstJar = try #require(first.session.configuration.httpCookieStorage)
        let secondJar = try #require(second.session.configuration.httpCookieStorage)
        #expect(first.session !== second.session)
        #expect(firstJar !== secondJar)
        #expect(firstJar !== HTTPCookieStorage.shared)

        let url = try #require(URL(string: "https://abs.example/socket.io/"))
        let cookie = try #require(
            HTTPCookie(properties: [.name: "proxy", .value: "account-a", .domain: "abs.example", .path: "/"]))
        firstJar.setCookies([cookie], for: url, mainDocumentURL: nil)

        #expect(firstJar.cookies(for: url)?.map(\.value) == ["account-a"])
        #expect(secondJar.cookies(for: url) ?? [] == [])
    }

    @Test func releasingAnIsolatedTransportInvalidatesItsSession() async {
        let delegate = InvalidationDelegate()
        var transport: URLSessionWebSocketTransport? = .isolated(
            configuration: .absConnection(), delegate: delegate, maximumMessageSize: 1024)
        #expect(transport != nil)
        transport = nil

        await delegate.invalidated.first { _ in true }
    }
}

/// Reports when its session becomes invalid.
private final class InvalidationDelegate: NSObject, URLSessionDelegate, Sendable {
    let invalidated: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    override init() {
        (invalidated, continuation) = AsyncStream.makeStream()
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        continuation.yield()
    }
}
