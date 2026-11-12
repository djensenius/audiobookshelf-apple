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

    /// Records whether the memory cache's lock was held when a bitmap's pixels were freed.
    private final class ReleaseProbe: Sendable {
        let cache: ImageMemoryCache
        let lockedOnRelease = Mutex<[Bool]>([])

        init(_ cache: ImageMemoryCache) {
            self.cache = cache
        }
    }

    /// A 4 × 4 bitmap (64 bytes) whose pixels report to `probe` when they are freed.
    private func probedBitmap(_ probe: ReleaseProbe) throws -> DecodedBitmap {
        let byteCount = 64
        let pixels = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        pixels.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        let provider = try #require(
            CGDataProvider(dataInfo: Unmanaged.passRetained(probe).toOpaque(), data: pixels, size: byteCount) {
                info, data, _ in
                guard let info else { return }
                let probe = Unmanaged<ReleaseProbe>.fromOpaque(info).takeRetainedValue()
                probe.lockedOnRelease.withLock { $0.append(probe.cache.isLocked) }
                UnsafeMutableRawPointer(mutating: data).deallocate()
            })
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(
            CGImage(
                width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return DecodedBitmap(image, ledger: probe.cache.ledger)
    }

    enum Removal: CaseIterable {
        case trim, removeAll, eviction, replacement
    }

    /// Bitmaps the LRU drops are freed after its lock is released, so a synchronous lookup on the
    /// main thread never waits for their deallocation.
    @Test(arguments: Removal.allCases)
    func droppedBitmapsAreFreedOutsideTheCacheLock(_ removal: Removal) throws {
        let ledger = ImageMemoryLedger()
        // Room for one bitmap.
        let cache = ImageMemoryCache(limit: 64, ledger: ledger)
        let probe = ReleaseProbe(cache)
        let key = MemoryKey(
            key: ImageKey(serverID: UUID(), kind: .itemCover, entityID: "a", updatedAt: 1),
            box: PixelBox(width: 4, height: 4))
        cache.insert(try probedBitmap(probe), for: key)
        switch removal {
        case .trim:
            cache.trim(toFraction: 0)
        case .removeAll:
            cache.removeAll { _ in true }
        case .eviction:
            #expect(cache.makeRoom(for: 1))
        case .replacement:
            cache.insert(try probedBitmap(ReleaseProbe(cache)), for: key)
        }
        #expect(probe.lockedOnRelease.withLock { $0 } == [false])
        // Freed by the time the call returns.
        #expect(ledger.total == (removal == .replacement ? 64 : 0))
        cache.removeAll { _ in true }
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

    @Test(arguments: ["http://127.0.0.1/admin", "http://[::1]/a", "http://192.168.1.1/a", "http://nas.local/a"])
    func aHopToThisDeviceOrTheLocalNetworkIsRefused(target: String) throws {
        let download = ImageDownload(original: original)
        #expect(try hop(download, from: "http://abs.example/a", to: target) == nil)
        // Also after a public hop.
        let other = ImageDownload(original: original)
        _ = try hop(other, from: "http://abs.example/a", to: "http://cdn.example/b")
        #expect(try hop(other, from: "http://cdn.example/b", to: target) == nil)
    }

    @Test func aLocalNetworkServerMayRedirectWithinItsOriginButNotElsewhereOnTheNetwork() throws {
        var request = URLRequest(url: try #require(URL(string: "http://192.168.1.5:13378/api/items/1/cover")))
        request.setValue("secret", forHTTPHeaderField: "CF-Access-Client-Secret")
        let download = ImageDownload(original: request)
        let same = try hop(download, from: "http://192.168.1.5:13378/a", to: "http://192.168.1.5:13378/b")
        #expect(same?.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")
        #expect(try hop(download, from: "http://192.168.1.5:13378/b", to: "http://192.168.1.5:8080/c") == nil)
        #expect(try hop(download, from: "http://192.168.1.5:13378/b", to: "http://192.168.1.6:13378/c") == nil)
    }

    @Test func aCrossOriginHopDropsAuthorization() throws {
        var request = original
        request.setValue("Bearer t", forHTTPHeaderField: "Authorization")
        let download = ImageDownload(original: request)
        let from = try #require(URL(string: "http://abs.example/a"))
        let response = try #require(HTTPURLResponse(url: from, statusCode: 302, httpVersion: nil, headerFields: nil))
        var proposed = URLRequest(url: try #require(URL(string: "https://cdn.example/b")))
        proposed.setValue("Bearer t", forHTTPHeaderField: "Authorization")
        let next = try #require(download.redirect(following: response, to: proposed))
        #expect(next.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(next.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
    }
}
