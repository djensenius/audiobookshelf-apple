import CoreGraphics
import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import ABSCore

@Suite struct ImagePipelineTests {
    private let directory: TemporaryDirectory
    private let serverID = UUID()

    init() throws {
        directory = try TemporaryDirectory()
    }

    private func makePipeline(
        host: String? = nil, headers: [String: String] = [:], limits: ImageCacheLimits = .iPhone,
        downloaded: [String: DownloadedCover] = [:], isOnline: @escaping @Sendable () -> Bool = { true }
    ) async -> (ImagePipeline, CoverFileStore) {
        let store = CoverFileStore(directory: directory.url.appending(path: "Images"), limit: limits.diskBytes)
        let pipeline = ImagePipeline(
            limits: limits, fileStore: store, downloadedCovers: FakeDownloadedCovers(covers: downloaded),
            sessionConfiguration: ImageStubProtocol.configuration(), isOnline: isOnline)
        if let host {
            await pipeline.setRequestBuilder(TestRequestBuilder(host: host, headers: headers), for: serverID)
        }
        return (pipeline, store)
    }

    private func key(_ id: String = "item-1", updatedAt: Int? = 1, url: URL? = nil) -> ImageKey {
        ImageKey(serverID: serverID, kind: .itemCover, entityID: id, updatedAt: updatedAt, externalURL: url)
    }

    private static func pngRoute(width: Int = 600, height: Int = 960, delay: Duration? = nil) -> String {
        ImageStubProtocol.register(
            .init(body: TestImages.data(width: width, height: height), mimeType: "image/png", delay: delay))
    }

    private static let gridBox = PixelBox(width: 512, height: 832)

    @Test func concurrentLoadsShareOneFetch() async throws {
        let host = Self.pngRoute(delay: .milliseconds(200))
        let (pipeline, _) = await makePipeline(host: host)
        let key = key()
        let images = try await withThrowingTaskGroup(of: CoverImage.self) { group in
            for _ in 0..<10 {
                group.addTask { try await pipeline.image(for: key, pixelBox: Self.gridBox) }
            }
            group.addTask { try await pipeline.image(for: key, pixelBox: PixelBox(width: 192, height: 288)) }
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
        let host = Self.pngRoute()
        let (pipeline, store) = await makePipeline(host: host)
        let first = try await pipeline.image(for: key(), pixelBox: Self.gridBox)
        let second = try await pipeline.image(for: key(), pixelBox: Self.gridBox)
        #expect(first.cgImage === second.cgImage)
        #expect(await store.size > 0)

        let (restarted, _) = await makePipeline(host: host)
        let fromDisk = try await restarted.image(for: key(), pixelBox: Self.gridBox)
        #expect(fromDisk.pixelWidth == first.pixelWidth)
        #expect(ImageStubProtocol.route(host)?.requests.count == 1)
        #expect(await restarted.networkFetchCount == 0)
    }

    @Test(arguments: [UTType.jpeg, .png])
    func downsamplesToTheBucket(type: UTType) async throws {
        let file = try TestImages.file(width: 4000, height: 3000, type: type, in: directory.url)
        let (pipeline, _) = await makePipeline()
        for bucket in ImageWidthBucket.allCases {
            let side = Double(bucket.rawValue)
            let image = try await pipeline.image(
                for: key(url: file).with(bucket: bucket), pixelBox: PixelBox(width: side, height: side))
            #expect(max(image.pixelWidth, image.pixelHeight) <= bucket.rawValue)
            #expect(image.pixelWidth == bucket.rawValue)
            #expect(image.cgImage.bitsPerComponent == 8)
            #expect(image.cost == image.cgImage.bytesPerRow * image.pixelHeight)
        }
    }

    @Test func squareCoverFitsTheGridBox() async throws {
        let file = try TestImages.file(width: 1000, height: 1000, in: directory.url)
        let (pipeline, _) = await makePipeline()
        let image = try await pipeline.image(for: key(url: file), pixelBox: Self.gridBox)
        #expect(image.pixelWidth == 512 && image.pixelHeight == 512)
    }

    @Test func localFileURLsAreReadDirectly() async throws {
        let file = try TestImages.file(width: 300, height: 480, type: .jpeg, in: directory.url)
        let (pipeline, store) = await makePipeline()
        let image = try await pipeline.cgImage(for: key(url: file), size: CGSize(width: 1200, height: 1200))
        #expect(image.width == 300 && image.height == 480)
        #expect(await pipeline.networkFetchCount == 0)
        #expect(await store.size == 0)
    }

    @Test func customHeadersAreSentWithoutCookiesOrToken() async throws {
        let host = Self.pngRoute()
        let headers = ["CF-Access-Client-Id": "client", "CF-Access-Client-Secret": "secret"]
        let (pipeline, _) = await makePipeline(host: host, headers: headers)
        _ = try await pipeline.image(for: key(), pixelBox: Self.gridBox)
        let request = try #require(ImageStubProtocol.route(host)?.requests.first)
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "client")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.url?.query()?.contains("token") == false)
    }

    @Test func httpErrorLeavesNoCacheEntry() async throws {
        let host = ImageStubProtocol.register(.init(status: 404, body: Data("missing".utf8), mimeType: "text/plain"))
        let (pipeline, store) = await makePipeline(host: host)
        await #expect(throws: ImagePipelineError.httpStatus(404)) {
            try await pipeline.image(for: key(), pixelBox: Self.gridBox)
        }
        #expect(await store.size == 0)
        #expect(await pipeline.memoryCost.lru == 0)
    }

    @Test func inputsOverFourMebibytesAreRejected() async throws {
        let host = ImageStubProtocol.register(.init(body: Data(count: 5 << 20), mimeType: "image/png"))
        let (pipeline, store) = await makePipeline(host: host)
        await #expect(throws: ImagePipelineError.tooLarge) {
            try await pipeline.image(for: key(), pixelBox: Self.gridBox)
        }
        #expect(await store.size == 0)
    }

    @Test func cancellingOneWaiterKeepsTheOthers() async throws {
        let host = Self.pngRoute(delay: .milliseconds(300))
        let (pipeline, _) = await makePipeline(host: host)
        let key = key()
        let leaving = Task { try await pipeline.image(for: key, pixelBox: Self.gridBox) }
        let staying = Task { try await pipeline.image(for: key, pixelBox: Self.gridBox) }
        try await eventually { ImageStubProtocol.route(host)?.requests.count == 1 }
        leaving.cancel()
        await #expect(throws: CancellationError.self) { try await leaving.value }
        let image = try await staying.value
        #expect(image.pixelWidth > 0)
        #expect(ImageStubProtocol.route(host)?.stopped == 0)
    }

    @Test func fetchIsCancelledWhenEveryWaiterLeaves() async throws {
        let host = Self.pngRoute(delay: .seconds(30))
        let (pipeline, store) = await makePipeline(host: host)
        let key = key()
        let tasks = [Self.gridBox, PixelBox(width: 192, height: 288)].map { box in
            Task { try await pipeline.image(for: key, pixelBox: box) }
        }
        try await eventually { ImageStubProtocol.route(host)?.requests.count == 1 }
        for task in tasks {
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        try await eventually { ImageStubProtocol.route(host)?.stopped == 1 }
        #expect(await store.size == 0)
    }

    @Test func gridOf500CoversStaysWithinTheMemoryBudget() async throws {
        let file = try TestImages.file(width: 600, height: 960, in: directory.url)
        let (pipeline, _) = await makePipeline(limits: .iPhone)
        let budget = ImageCacheLimits.iPhone.memoryBytes
        var visible: [CoverImage] = []
        var peak = 0
        for index in 0..<500 {
            let image = try await pipeline.image(for: key("item-\(index)", url: file), pixelBox: Self.gridBox)
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
        let file = try TestImages.file(width: 512, height: 512, in: directory.url)
        let mebibyte = 1 << 20
        let limits = ImageCacheLimits(memoryBytes: 5 * mebibyte / 2, diskBytes: mebibyte, maxConcurrentDecodes: 2)
        let (pipeline, _) = await makePipeline(limits: limits)
        let box = PixelBox(width: 512, height: 512)
        var held = [
            try await pipeline.image(for: key("a", url: file), pixelBox: box),
            try await pipeline.image(for: key("b", url: file), pixelBox: box),
        ]
        let finished = Mutex(false)
        let third = Task {
            let image = try await pipeline.image(for: key("c", url: file), pixelBox: box)
            finished.withLock { $0 = true }
            return image
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(finished.withLock { $0 } == false)
        held.removeFirst()
        let image = try await third.value
        #expect(image.pixelWidth == 512)
        #expect(await pipeline.memoryCost.combined <= limits.memoryBytes)
    }

    @Test func offlinePrefersTheExactCachedVersionThenTheStaleDownload() async throws {
        let online = Mutex(true)
        let host = Self.pngRoute(width: 200, height: 320)
        let downloaded = try TestImages.file(width: 100, height: 160, in: directory.url)
        let covers = ["item-1": DownloadedCover(fileURL: downloaded, updatedAt: 1)]
        let box = PixelBox(width: 1200, height: 1200)

        // Version 2 is on disk: offline, it beats the older downloaded cover.
        let (warm, _) = await makePipeline(host: host)
        _ = try await warm.image(for: key(updatedAt: 2), pixelBox: Self.gridBox)
        let (offline, _) = await makePipeline(host: host, downloaded: covers) { online.withLock { $0 } }
        online.withLock { $0 = false }
        #expect(try await offline.image(for: key(updatedAt: 2), pixelBox: box).pixelWidth == 200)

        // Version 3 isn't cached: offline shows the stale download without caching it as v3.
        let stale = try await offline.image(for: key(updatedAt: 3), pixelBox: box)
        #expect(stale.pixelWidth == 100)
        let requests = ImageStubProtocol.route(host)?.requests.count
        online.withLock { $0 = true }
        let fresh = try await offline.image(for: key(updatedAt: 3), pixelBox: box)
        #expect(fresh.pixelWidth == 200)
        #expect(ImageStubProtocol.route(host)?.requests.count == (requests ?? 0) + 1)
    }

    private func eventually(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

@Suite struct ImageKeyTests {
    @Test func bucketsAndPixelBoxes() {
        #expect(ImageWidthBucket(pixelWidth: 180) == .small)
        #expect(ImageWidthBucket(pixelWidth: 510) == .medium)
        #expect(ImageWidthBucket(pixelWidth: 2048) == .large)
        let box = PixelBox(size: CGSize(width: 170, height: 272), scale: 3)
        #expect(box == PixelBox(width: 512, height: 832))
        #expect(PixelBox(width: 5000, height: 1).height == 32 && PixelBox(width: 5000, height: 1).width == 1200)
    }

    @Test func fileStemIsSanitised() {
        let key = ImageKey(
            serverID: UUID(), kind: .authorImage, entityID: "../a/b", updatedAt: 42, bucket: .small)
        #expect(key.fileStem == "authorImage-___a_b-42-300")
    }
}
