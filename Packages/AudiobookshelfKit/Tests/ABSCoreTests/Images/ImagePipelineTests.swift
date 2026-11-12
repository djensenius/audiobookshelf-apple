import CoreGraphics
import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import ABSCore

@Suite(.timeLimit(.minutes(1))) struct ImagePipelineTests {
    private let harness: PipelineHarness
    private let gridBox = PipelineHarness.gridBox

    init() throws {
        harness = try PipelineHarness()
    }

    private var directory: URL { harness.directory.url }

    private func key(_ id: String = "item-1", updatedAt: Int? = 1, url: URL? = nil) -> ImageKey {
        harness.key(id, updatedAt: updatedAt, url: url)
    }

    @Test func concurrentLoadsShareOneFetch() async throws {
        let gate = Gate()
        let host = PipelineHarness.pngRoute(gate: gate)
        let (pipeline, _) = await harness.make(host: host)
        let key = key()
        let (gridBox, smallBox) = (gridBox, PixelBox(width: 192, height: 288))
        let images = try await withThrowingTaskGroup(of: CoverImage.self) { group in
            for _ in 0..<10 {
                group.addTask { try await pipeline.image(for: key, pixelBox: gridBox) }
            }
            group.addTask { try await pipeline.image(for: key, pixelBox: smallBox) }
            // Every caller joins before the response, so none can start a second fetch.
            #expect(await pipeline.waitForWaiters(key, box: gridBox, fetch: 2, decode: 10))
            #expect(await pipeline.waitForWaiters(key, box: smallBox, fetch: 2, decode: 1))
            gate.open()
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(ImageStubProtocol.route(host)?.requests.count == 1)
        #expect(await pipeline.networkFetchCount == 1)
        let grid = images.filter { $0.pixelWidth > 200 }
        #expect(grid.count == 10)
        #expect(grid.allSatisfy { $0.cgImage === grid[0].cgImage })
        #expect(images.contains { $0.pixelWidth <= 192 && $0.pixelHeight <= 288 })
    }

    @Test func memoryThenDiskHitsAfterRestart() async throws {
        let host = PipelineHarness.pngRoute()
        let (pipeline, store) = await harness.make(host: host)
        let first = try await pipeline.image(for: key(), pixelBox: gridBox)
        let second = try await pipeline.image(for: key(), pixelBox: gridBox)
        #expect(first.cgImage === second.cgImage)
        #expect(await store.size > 0)

        let (restarted, _) = await harness.make(host: host)
        let fromDisk = try await restarted.image(for: key(), pixelBox: gridBox)
        #expect(fromDisk.pixelWidth == first.pixelWidth)
        #expect(ImageStubProtocol.route(host)?.requests.count == 1)
        #expect(await restarted.networkFetchCount == 0)
    }

    @Test(arguments: [UTType.jpeg, .png])
    func downsamplesToTheBucket(type: UTType) async throws {
        let file = try TestImages.file(width: 4000, height: 3000, type: type, in: directory)
        let (pipeline, _) = await harness.make(local: file)
        for bucket in ImageWidthBucket.allCases {
            let side = Double(bucket.rawValue)
            let image = try await pipeline.image(
                for: key().with(bucket: bucket), pixelBox: PixelBox(width: side, height: side))
            #expect(max(image.pixelWidth, image.pixelHeight) <= bucket.rawValue)
            #expect(image.pixelWidth == bucket.rawValue)
            #expect(image.cgImage.bitsPerComponent == 8)
            #expect(image.cost == image.cgImage.bytesPerRow * image.pixelHeight)
        }
    }

    @Test func squareCoverFitsTheGridBox() async throws {
        let file = try TestImages.file(width: 1000, height: 1000, in: directory)
        let (pipeline, _) = await harness.make(local: file)
        let image = try await pipeline.image(for: key(), pixelBox: gridBox)
        #expect(image.pixelWidth == 512 && image.pixelHeight == 512)
    }

    @Test func downloadedCoversAreReadDirectly() async throws {
        let file = try TestImages.file(width: 300, height: 480, type: .jpeg, in: directory)
        let (pipeline, store) = await harness.make(local: file)
        let image = try await pipeline.cgImage(for: key(), size: CGSize(width: 1200, height: 1200))
        #expect(image.width == 300 && image.height == 480)
        #expect(await pipeline.networkFetchCount == 0)
        #expect(await store.size == 0)
    }

    @Test func fileExternalURLsAreRejected() async throws {
        let file = try TestImages.file(width: 300, height: 480, in: directory)
        let (pipeline, _) = await harness.make()
        await #expect(throws: ImagePipelineError.noRequest) {
            try await pipeline.image(for: key(url: file), pixelBox: gridBox)
        }
    }

    @Test func customHeadersAreSentWithoutCookiesOrToken() async throws {
        let host = PipelineHarness.pngRoute()
        let headers = [
            "CF-Access-Client-Id": "client", "CF-Access-Client-Secret": "secret", "Authorization": "Bearer t",
            "Cookie": "connect.sid=1",
        ]
        let configuration = ImageStubProtocol.configuration()
        configuration.httpAdditionalHeaders = ["Authorization": "Bearer session", "X-Session": "1"]
        let (pipeline, _) = await harness.make(host: host, headers: headers, configuration: configuration)
        _ = try await pipeline.image(for: key(), pixelBox: gridBox)
        let request = try #require(ImageStubProtocol.route(host)?.requests.first)
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "client")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Session") == nil)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.url?.query()?.contains("token") == false)
        // The caller's configuration is copied, not changed.
        #expect(configuration.httpAdditionalHeaders?["X-Session"] as? String == "1")
    }

    @Test func crossOriginRedirectStripsHeadersAndCookiesAreNeitherSentNorStored() async throws {
        let target = ImageStubProtocol.register(
            .init(body: TestImages.data(width: 600, height: 960), headers: ["Set-Cookie": "cdn=1; Path=/"]))
        let origin = ImageStubProtocol.register(
            .init(headers: ["Set-Cookie": "origin=1; Path=/"], redirectTo: "https://\(target)/cover.png"))
        let seeded = try #require(
            HTTPCookie(properties: [.domain: origin, .path: "/", .name: "connect.sid", .value: "session"]))
        HTTPCookieStorage.shared.setCookie(seeded)
        defer { HTTPCookieStorage.shared.deleteCookie(seeded) }
        // The caller's configuration would send and store cookies; the pipeline turns that off.
        let configuration = ImageStubProtocol.configuration()
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        let headers = [
            "CF-Access-Client-Id": "client", "CF-Access-Client-Secret": "secret", "Authorization": "Bearer t",
        ]
        let (pipeline, _) = await harness.make(host: origin, headers: headers, configuration: configuration)
        _ = try await pipeline.image(for: key(), pixelBox: gridBox)

        let first = try #require(ImageStubProtocol.route(origin)?.requests.first)
        #expect(first.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")
        #expect(first.value(forHTTPHeaderField: "Cookie") == nil)
        let hop = try #require(ImageStubProtocol.route(target)?.requests.first)
        for name in ["CF-Access-Client-Id", "CF-Access-Client-Secret", "Authorization", "Cookie"] {
            #expect(hop.value(forHTTPHeaderField: name) == nil, "\(name)")
        }
        #expect(hop.value(forHTTPHeaderField: "Accept") == "image/*")
        // URLSession doesn't attach or store cookies for a custom URLProtocol, so the checks
        // that catch a regression here are the per-request flags; the storage checks document it.
        #expect(first.httpShouldHandleCookies == false)
        #expect(hop.httpShouldHandleCookies == false)
        for host in [origin, target] {
            let stored = HTTPCookieStorage.shared.cookies(for: try #require(URL(string: "https://\(host)/"))) ?? []
            #expect(stored.map(\.name).filter { $0 != "connect.sid" }.isEmpty)
        }
    }

    @Test func httpErrorLeavesNoCacheEntry() async throws {
        let host = ImageStubProtocol.register(.init(status: 404, body: Data("missing".utf8), mimeType: "text/plain"))
        let (pipeline, store) = await harness.make(host: host)
        await #expect(throws: ImagePipelineError.httpStatus(404)) {
            try await pipeline.image(for: key(), pixelBox: gridBox)
        }
        #expect(await store.size == 0)
        #expect(await pipeline.memoryCost.lru == 0)
    }

    @Test func cancellingOneWaiterKeepsTheOthers() async throws {
        let gate = Gate()
        let host = PipelineHarness.pngRoute(gate: gate)
        let (pipeline, _) = await harness.make(host: host)
        let (key, gridBox) = (key(), gridBox)
        let leaving = Task { try await pipeline.image(for: key, pixelBox: gridBox) }
        let staying = Task { try await pipeline.image(for: key, pixelBox: gridBox) }
        await ImageStubProtocol.wait(for: host) { $0.requests.count == 1 }
        // Cancelling before `staying` joins would abandon the only waiter's fetch.
        #expect(await pipeline.waitForWaiters(key, box: gridBox, fetch: 1, decode: 2))
        leaving.cancel()
        await #expect(throws: CancellationError.self) { try await leaving.value }
        gate.open()
        let image = try await staying.value
        #expect(image.pixelWidth > 0)
        #expect(ImageStubProtocol.route(host)?.stopped == 0)
    }

    @Test func fetchContinuesWhileAnotherBoxWaits() async throws {
        let gate = Gate()
        let host = PipelineHarness.pngRoute(gate: gate)
        let (pipeline, _) = await harness.make(host: host)
        let (key, gridBox) = (key(), gridBox)
        let leaving = Task { try await pipeline.image(for: key, pixelBox: gridBox) }
        let staying = Task { try await pipeline.image(for: key, pixelBox: PixelBox(width: 192, height: 288)) }
        await ImageStubProtocol.wait(for: host) { $0.requests.count == 1 }
        #expect(await pipeline.waitForWaiters(key, box: gridBox, fetch: 2, decode: 1))
        leaving.cancel()
        await #expect(throws: CancellationError.self) { try await leaving.value }
        gate.open()
        #expect(try await staying.value.pixelHeight <= 288)
        #expect(ImageStubProtocol.route(host)?.stopped == 0)
        #expect(ImageStubProtocol.route(host)?.requests.count == 1)
    }

    @Test func fetchIsCancelledWhenEveryWaiterLeaves() async throws {
        let host = PipelineHarness.pngRoute(gate: Gate())
        let (pipeline, store) = await harness.make(host: host)
        let key = key()
        let tasks = [gridBox, PixelBox(width: 192, height: 288)].map { box in
            Task { try await pipeline.image(for: key, pixelBox: box) }
        }
        await ImageStubProtocol.wait(for: host) { $0.requests.count == 1 }
        for task in tasks {
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        await ImageStubProtocol.wait(for: host) { $0.stopped == 1 }
        #expect(await store.size == 0)
    }

    @Test func gridOf500CoversStaysWithinTheMemoryBudget() async throws {
        let file = try TestImages.file(width: 600, height: 960, in: directory)
        let (pipeline, _) = await harness.make(limits: .iPhone, local: file)
        let budget = ImageCacheLimits.iPhone.memoryBytes
        var visible: [CoverImage] = []
        var peak = 0
        for index in 0..<500 {
            let image = try await pipeline.image(for: key("item-\(index)"), pixelBox: gridBox)
            #expect(image.pixelWidth <= 512 && image.pixelHeight <= 832)
            // A lazy grid keeps about 30 covers alive.
            visible.append(image)
            if visible.count > 30 { visible.removeFirst() }
            peak = max(peak, await pipeline.memoryCost.combined)
        }
        #expect(peak <= budget)
        let cost = await pipeline.memoryCost
        #expect(cost.lru <= budget && cost.combined <= budget)
        #expect(cost.lru > budget / 2)
    }

    @Test func liveImagesCountAgainstTheCapUntilReleased() async throws {
        let file = try TestImages.file(width: 512, height: 512, in: directory)
        let mebibyte = 1 << 20
        let limits = ImageCacheLimits(memoryBytes: 5 * mebibyte / 2, diskBytes: mebibyte, maxConcurrentDecodes: 2)
        let (pipeline, _) = await harness.make(limits: limits, local: file)
        let box = PixelBox(width: 512, height: 512)
        var held = [
            try await pipeline.image(for: key("a"), pixelBox: box),
            try await pipeline.image(for: key("b"), pixelBox: box),
        ]
        let finished = Mutex(false)
        let third = Task { [key = key("c")] in
            let image = try await pipeline.image(for: key, pixelBox: box)
            finished.withLock { $0 = true }
            return image
        }
        while await pipeline.memoryWaiterCount == 0 { await Task.yield() }
        #expect(finished.withLock { $0 } == false)
        held.removeFirst()
        let image = try await third.value
        #expect(image.pixelWidth == 512)
        #expect(await pipeline.memoryCost.combined <= limits.memoryBytes)
    }

    @Test func offlinePrefersTheExactCachedVersionThenTheStaleDownload() async throws {
        let online = Mutex(true)
        let host = PipelineHarness.pngRoute(width: 200, height: 320)
        let downloaded = try TestImages.file(width: 100, height: 160, in: directory)
        let covers = ["item-1": DownloadedCover(fileURL: downloaded, updatedAt: 1)]
        let box = PixelBox(width: 1200, height: 1200)

        // Version 2 is on disk: offline, it beats the older downloaded cover.
        let (warm, _) = await harness.make(host: host)
        _ = try await warm.image(for: key(updatedAt: 2), pixelBox: gridBox)
        let (offline, _) = await harness.make(host: host, downloaded: covers) { online.withLock { $0 } }
        online.withLock { $0 = false }
        #expect(try await offline.image(for: key(updatedAt: 2), pixelBox: box).pixelWidth == 200)

        // Version 3 isn't cached: offline shows the stale download without caching it as v3.
        let stale = try await offline.image(for: key(updatedAt: 3), pixelBox: box)
        #expect(stale.pixelWidth == 100)
        #expect(stale.updatedAt == 1)
        let requests = ImageStubProtocol.route(host)?.requests.count
        online.withLock { $0 = true }
        let fresh = try await offline.image(for: key(updatedAt: 3), pixelBox: box)
        #expect(fresh.pixelWidth == 200)
        #expect(fresh.updatedAt == 3)
        #expect(ImageStubProtocol.route(host)?.requests.count == (requests ?? 0) + 1)
    }
}
