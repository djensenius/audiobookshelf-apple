import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import ABSCore

@Suite(.timeLimit(.minutes(1))) struct ImageInternalsTests {
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

@Suite struct ImageDownloadRedirectTests {
    private let original: URLRequest

    init() throws {
        var request = URLRequest(url: try #require(URL(string: "http://abs.example/api/items/1/cover")))
        request.setValue("secret", forHTTPHeaderField: "CF-Access-Client-Secret")
        request.setValue("image/webp", forHTTPHeaderField: "Accept")
        original = request
    }

    private func hop(
        _ download: ImageDownload, from: String, to: String
    ) throws -> URLRequest? {
        let from = try #require(URL(string: from))
        let response = try #require(HTTPURLResponse(url: from, statusCode: 302, httpVersion: nil, headerFields: nil))
        var proposed = URLRequest(url: try #require(URL(string: to)))
        proposed.setValue("secret", forHTTPHeaderField: "CF-Access-Client-Secret")
        return download.redirect(following: response, to: proposed)
    }

    @Test func sameOriginAndUpgradeKeepHeaders() throws {
        let download = ImageDownload(original: original)
        let same = try hop(download, from: "http://abs.example/a", to: "http://abs.example/b")
        #expect(same?.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")
        let upgrade = try hop(download, from: "http://abs.example/b", to: "https://abs.example/c")
        #expect(upgrade?.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")
        #expect(upgrade?.httpShouldHandleCookies == false)
    }

    @Test func crossOriginStripsAndStaysStrippedBackOnTheOrigin() throws {
        let download = ImageDownload(original: original)
        let cross = try hop(download, from: "http://abs.example/a", to: "http://cdn.example/b")
        #expect(cross?.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
        #expect(cross?.value(forHTTPHeaderField: "Accept") == "image/webp")
        #expect(cross?.httpShouldHandleCookies == false)
        let back = try hop(download, from: "http://cdn.example/b", to: "http://abs.example/c")
        #expect(back?.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
        #expect(back?.httpShouldHandleCookies == false)
    }

    @Test func portChangeIsCrossOrigin() throws {
        let download = ImageDownload(original: original)
        let next = try hop(download, from: "http://abs.example/a", to: "http://abs.example:8080/b")
        #expect(next?.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
    }

    @Test func downgradeIsRefused() throws {
        let download = ImageDownload(original: original)
        #expect(try hop(download, from: "https://abs.example/a", to: "http://abs.example/b") == nil)
    }
}
