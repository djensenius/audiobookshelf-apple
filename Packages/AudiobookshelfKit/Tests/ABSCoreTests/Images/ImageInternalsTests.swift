import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import ABSCore

@Suite(.timeLimit(.minutes(1))) struct ImageInternalsTests {
    @Test func callerCancelledBeforeJoiningAbandonsTheFlight() async throws {
        let (finished, finish) = AsyncStream.makeStream(of: Bool.self)
        let flight = Flight<Int>()
        flight.start {
            defer { finish.finish() }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                finish.yield(Task.isCancelled)
                throw error
            }
            return 1
        }
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await flight.join()
        }
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(flight.isAbandoned)
        var iterator = finished.makeAsyncIterator()
        #expect(await iterator.next() == true)
    }

    @Test func returnedReservationWakesAWaitingDecode() async {
        let ledger = ImageMemoryLedger()
        ledger.reserve(100)
        let generation = ledger.generation
        let waiter = Task { await ledger.waitForRelease(after: generation) }
        while ledger.waiterCount == 0 { await Task.yield() }
        // A decode that reserved room and then failed hands it back.
        ledger.unreserve(100)
        await waiter.value
        #expect(ledger.total == 0)
    }

    @Test func onlyStandardLayoutsSkipNormalizing() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        func image(_ alpha: CGImageAlphaInfo, _ order: CGImageByteOrderInfo) throws -> CGImage {
            let context = try #require(
                CGContext(
                    data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: alpha.rawValue | order.rawValue))
            return try #require(context.makeImage())
        }
        #expect(!ImageDecoder.needsNormalizing(try image(.premultipliedFirst, .order32Little)))
        #expect(!ImageDecoder.needsNormalizing(try image(.premultipliedLast, .orderDefault)))
        // ARGB, ImageIO's own output.
        #expect(!ImageDecoder.needsNormalizing(try image(.premultipliedFirst, .order32Big)))
        // ABGR.
        #expect(ImageDecoder.needsNormalizing(try image(.premultipliedLast, .order32Little)))
    }
}

@Suite struct ImageTaskDelegateTests {
    private let original: URLRequest

    init() throws {
        var request = URLRequest(url: try #require(URL(string: "http://abs.example/api/items/1/cover")))
        request.setValue("secret", forHTTPHeaderField: "CF-Access-Client-Secret")
        request.setValue("image/webp", forHTTPHeaderField: "Accept")
        original = request
    }

    private func hop(
        _ delegate: ImageTaskDelegate, from: String, to: String
    ) async throws -> URLRequest? {
        let from = try #require(URL(string: from))
        let response = try #require(HTTPURLResponse(url: from, statusCode: 302, httpVersion: nil, headerFields: nil))
        var proposed = URLRequest(url: try #require(URL(string: to)))
        proposed.setValue("secret", forHTTPHeaderField: "CF-Access-Client-Secret")
        return await delegate.urlSession(
            .shared, task: URLSession.shared.dataTask(with: from), willPerformHTTPRedirection: response,
            newRequest: proposed)
    }

    @Test func sameOriginAndUpgradeKeepHeaders() async throws {
        let delegate = ImageTaskDelegate(original: original)
        let same = try await hop(delegate, from: "http://abs.example/a", to: "http://abs.example/b")
        #expect(same?.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")
        let upgrade = try await hop(delegate, from: "http://abs.example/b", to: "https://abs.example/c")
        #expect(upgrade?.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")
        #expect(upgrade?.httpShouldHandleCookies == false)
    }

    @Test func crossOriginStripsAndStaysStrippedBackOnTheOrigin() async throws {
        let delegate = ImageTaskDelegate(original: original)
        let cross = try await hop(delegate, from: "http://abs.example/a", to: "http://cdn.example/b")
        #expect(cross?.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
        #expect(cross?.value(forHTTPHeaderField: "Accept") == "image/webp")
        #expect(cross?.httpShouldHandleCookies == false)
        let back = try await hop(delegate, from: "http://cdn.example/b", to: "http://abs.example/c")
        #expect(back?.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
        #expect(back?.httpShouldHandleCookies == false)
    }

    @Test func portChangeIsCrossOrigin() async throws {
        let delegate = ImageTaskDelegate(original: original)
        let next = try await hop(delegate, from: "http://abs.example/a", to: "http://abs.example:8080/b")
        #expect(next?.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
    }

    @Test func downgradeIsRefused() async throws {
        let delegate = ImageTaskDelegate(original: original)
        #expect(try await hop(delegate, from: "https://abs.example/a", to: "http://abs.example/b") == nil)
    }
}
