import CoreGraphics
import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import ABSCore

/// ADR 0005's validation list: input limits, bad responses, server removal, decode slots and
/// formats.
@Suite(.timeLimit(.minutes(1))) struct ImagePipelineValidationTests {
    private let harness: PipelineHarness
    private let gridBox = PipelineHarness.gridBox

    init() throws {
        harness = try PipelineHarness()
    }

    private var directory: URL { harness.directory.url }

    @Test func streamedBodyIsCancelledPastFourMebibytes() async throws {
        // The last chunk waits until the load is stopped, so it can only be stopped early.
        let chunks = 8
        let finalChunk = Gate()
        let host = ImageStubProtocol.register(
            .init(
                body: Data(count: chunks << 20), chunkSize: 1 << 20, chunkDelay: .zero, finalChunkGate: finalChunk,
                contentLength: .some(nil)))
        let (pipeline, store) = await harness.make(host: host)
        await #expect(throws: ImagePipelineError.tooLarge) {
            try await pipeline.image(for: harness.key(), pixelBox: gridBox)
        }
        await ImageStubProtocol.wait(for: host) { $0.stopped == 1 }
        finalChunk.open()
        #expect((ImageStubProtocol.route(host)?.chunksSent ?? chunks) < chunks)
        #expect(await store.size == 0)
    }

    @Test func contentLengthOverFourMebibytesIsRejectedBeforeTheBody() async throws {
        // URLSession delivers the response with the first bytes. The fifth chunk, which would
        // take the count past the cap, waits for the gate, so only the header can end the load.
        let finalChunk = Gate()
        let host = ImageStubProtocol.register(
            .init(body: Data(count: 5 << 20), chunkSize: 1 << 20, chunkDelay: .zero, finalChunkGate: finalChunk))
        let (pipeline, store) = await harness.make(host: host)
        await #expect(throws: ImagePipelineError.tooLarge) {
            try await pipeline.image(for: harness.key(), pixelBox: gridBox)
        }
        #expect((ImageStubProtocol.route(host)?.chunksSent ?? 5) < 5)
        finalChunk.open()
        #expect(await store.size == 0)
    }

    @Test func oversizeStoredFileIsRejectedUnread() async throws {
        let (pipeline, store) = await harness.make()
        let key = harness.key()
        let file = store.directory.appending(path: "\(key.serverID.uuidString)/\(key.fileStem).png")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: ImageCacheLimits.maxInputBytes + 1).write(to: file)
        await #expect(throws: ImagePipelineError.tooLarge) {
            try await pipeline.image(for: key, pixelBox: gridBox)
        }
        #expect(await pipeline.networkFetchCount == 0)
    }

    @Test func oversizeDownloadedCoverIsSkippedForTheServerCover() async throws {
        let host = PipelineHarness.pngRoute()
        let original = directory.appending(path: "original.jpg")
        try Data(count: ImageCacheLimits.maxInputBytes + 1).write(to: original)
        let (pipeline, _) = await harness.make(host: host, local: original)
        let image = try await pipeline.image(for: harness.key(), pixelBox: gridBox)
        #expect(image.pixelWidth > 0)
        #expect(ImageStubProtocol.route(host)?.requests.count == 1)

        let (offline, _) = await harness.make(host: host, local: original, isOnline: { false })
        await #expect(throws: ImagePipelineError.offline) {
            try await offline.image(for: harness.key("never-fetched"), pixelBox: gridBox)
        }
    }

    @Test func failedFinalRenameStillShowsTheDownloadOnce() async throws {
        let host = PipelineHarness.pngRoute()
        let (pipeline, store) = await harness.make(host: host)
        let key = harness.key()
        // A non-empty folder where the cover belongs makes the store's final rename fail.
        let folder = store.directory.appending(path: key.serverID.uuidString)
        let blocker = folder.appending(path: "\(key.fileStem).png")
        try FileManager.default.createDirectory(at: blocker.appending(path: "x"), withIntermediateDirectories: true)
        var image: CoverImage? = try await pipeline.image(for: key, pixelBox: gridBox)
        #expect((image?.pixelWidth ?? 0) > 0)
        #expect(ImageStubProtocol.route(host)?.requests.count == 1)
        #expect(await store.size == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [blocker.lastPathComponent])
        image = nil
        await pipeline.trimMemory(toFraction: 0)
        let temporary = pipeline.temporaryFolder.path
        try await yieldUntil { ((try? FileManager.default.contentsOfDirectory(atPath: temporary)) ?? []).isEmpty }
    }

    @Test func nonImageSuccessIsNotCached() async throws {
        let host = ImageStubProtocol.register(.init(body: Data("<html>Sign in</html>".utf8), mimeType: "text/html"))
        let (pipeline, store) = await harness.make(host: host)
        await #expect(throws: ImagePipelineError.unsupportedImage) {
            try await pipeline.image(for: harness.key(), pixelBox: gridBox)
        }
        #expect(await store.size == 0)
    }

    @Test func damagedStoredFileIsDeletedAndRefetched() async throws {
        let host = PipelineHarness.pngRoute()
        let (pipeline, store) = await harness.make(host: host)
        let key = harness.key()
        let file = store.directory.appending(path: "\(key.serverID.uuidString)/\(key.fileStem).png")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TestImages.data(width: 600, height: 960).prefix(100).write(to: file)
        _ = try await pipeline.image(for: key, pixelBox: gridBox)
        #expect(ImageStubProtocol.route(host)?.requests.count == 1)
        #expect(await ImageDecoder.isImage(file))
    }

    @Test func secondResponseIsRejectedWithoutOrphanedFiles() async throws {
        let body = TestImages.data(width: 600, height: 960)
        let host = ImageStubProtocol.register(
            .init(
                body: body, mimeType: "multipart/x-mixed-replace; boundary=frame", chunkSize: body.count / 2 + 1,
                chunkDelay: .zero, repeatsResponse: true))
        let (pipeline, _) = await harness.make(host: host)
        await #expect(throws: ImagePipelineError.unsupportedImage) {
            try await pipeline.image(for: harness.key(), pixelBox: gridBox)
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: pipeline.temporaryFolder.path)) ?? []
        #expect(left.isEmpty)
    }

    @Test func removedServerFetchesNothingUntilItsBuilderIsSetAgain() async throws {
        let host = PipelineHarness.pngRoute()
        let (pipeline, store) = await harness.make(host: host)
        await pipeline.removeServer(harness.serverID)
        let external = harness.key(url: URL(string: "https://\(host)/cover.png"))
        await #expect(throws: ImagePipelineError.noRequest) {
            try await pipeline.image(for: external, pixelBox: gridBox)
        }
        let folder = store.directory.appending(path: harness.serverID.uuidString)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        await pipeline.setRequestBuilder(TestRequestBuilder(host: host), for: harness.serverID)
        _ = try await pipeline.image(for: harness.key(), pixelBox: gridBox)
    }

    @Test func anExternalCoverOnThisDeviceIsNeverFetchedWithoutABuilder() async throws {
        let store = CoverFileStore(directory: directory.appending(path: "Images"), limit: 1 << 20)
        let pipeline = ImagePipeline(
            limits: .iPhone, fileStore: store, sessionConfiguration: ImageStubProtocol.configuration())
        let local = harness.key(url: URL(string: "http://127.0.0.1:8080/admin/reboot"))
        await #expect(throws: ImagePipelineError.noRequest) {
            try await pipeline.image(for: local, pixelBox: gridBox)
        }
        #expect(await pipeline.networkFetchCount == 0)
    }

    @Test func aPlainHTTPExternalCoverIsNeverFetchedButHTTPSIs() async throws {
        let host = PipelineHarness.pngRoute()
        let store = CoverFileStore(directory: directory.appending(path: "Images"), limit: 1 << 20)
        let pipeline = ImagePipeline(
            limits: .iPhone, fileStore: store, sessionConfiguration: ImageStubProtocol.configuration())
        await #expect(throws: ImagePipelineError.noRequest) {
            try await pipeline.image(for: harness.key(url: URL(string: "http://\(host)/cover.png")), pixelBox: gridBox)
        }
        #expect(await pipeline.networkFetchCount == 0)
        _ = try await pipeline.image(for: harness.key(url: URL(string: "https://\(host)/cover.png")), pixelBox: gridBox)
        #expect(await pipeline.networkFetchCount == 1)
    }

    @Test func removedServerSkipsDownloadedCoversUntilItsBuilderIsSetAgain() async throws {
        let covers = CountingCovers(file: try TestImages.file(width: 100, height: 160, in: directory))
        let store = CoverFileStore(directory: directory.appending(path: "Images"), limit: 1 << 20)
        let pipeline = ImagePipeline(
            limits: .iPhone, fileStore: store, downloadedCovers: covers,
            sessionConfiguration: ImageStubProtocol.configuration())
        await pipeline.removeServer(harness.serverID)
        await #expect(throws: ImagePipelineError.noRequest) {
            try await pipeline.image(for: harness.key(), pixelBox: gridBox)
        }
        await #expect(throws: ImagePipelineError.noRequest) {
            try await pipeline.cgImage(for: harness.key(), size: CGSize(width: 100, height: 160))
        }
        #expect(covers.calls.withLock { $0 } == 0)
        #expect(await pipeline.memoryCost.lru == 0)
        await pipeline.setRequestBuilder(TestRequestBuilder(host: "unused.images.test"), for: harness.serverID)
        _ = try await pipeline.image(for: harness.key(), pixelBox: gridBox)
        #expect(covers.calls.withLock { $0 } == 1)
    }

    @Test func removingAServerCancelsItsFetchesAndPurgesItsImages() async throws {
        let gate = Gate()
        let host = PipelineHarness.pngRoute(gate: gate)
        let seen = try TestImages.file(width: 100, height: 160, in: directory)
        let (pipeline, store) = await harness.make(
            host: host, downloaded: ["seen": DownloadedCover(fileURL: seen, updatedAt: 1)])
        _ = try await pipeline.image(for: harness.key("seen"), pixelBox: gridBox)
        #expect(await pipeline.memoryCost.lru > 0)

        let (key, gridBox) = (harness.key(), gridBox)
        let loading = Task { try await pipeline.image(for: key, pixelBox: gridBox) }
        await ImageStubProtocol.wait(for: host) { $0.requests.count == 1 }
        await pipeline.removeServer(harness.serverID)
        gate.open()
        await #expect(throws: CancellationError.self) { try await loading.value }
        #expect(await store.size == 0)
        #expect(await pipeline.memoryCost.lru == 0)
    }

    @Test func largeBoxesAndNormalizingDecodesTakeTheLargeSlot() async throws {
        let file = try TestImages.file(width: 1200, height: 1200, in: directory)
        let (pipeline, _) = await harness.make(local: file)
        _ = try await pipeline.image(for: harness.key("grid").with(bucket: .large), pixelBox: gridBox)
        #expect(await pipeline.largeDecodeCount == 0)
        _ = try await pipeline.image(
            for: harness.key("player").with(bucket: .large), pixelBox: PixelBox(width: 1200, height: 1200))
        #expect(await pipeline.largeDecodeCount == 1)
    }

    /// A 16-bit source becomes 8-bit premultiplied in its own gamut: sRGB stays sRGB, and a
    /// Display P3 source stays Display P3 rather than being clipped to sRGB.
    @Test(arguments: [CGColorSpace.sRGB as String, CGColorSpace.displayP3 as String])
    func sixteenBitSourcesAreNormalizedToEightBit(space: String) async throws {
        let file = try TestImages.file(
            width: 600, height: 960, bitsPerComponent: 16, space: space as CFString, in: directory)
        let (pipeline, _) = await harness.make(local: file)
        let image = try await pipeline.image(for: harness.key(), pixelBox: gridBox)
        #expect(image.cgImage.bitsPerComponent == 8)
        #expect([.premultipliedFirst, .premultipliedLast].contains(image.cgImage.alphaInfo))
        #expect(image.cgImage.colorSpace?.name as String? == space)
        #expect(!ImageDecoder.needsNormalizing(image.cgImage))
        #expect(await pipeline.largeDecodeCount == 1)
    }

    @Test func floatSourcesAreRejected() async throws {
        let file = try TestImages.file(
            width: 64, height: 64, type: .tiff, bitsPerComponent: 32, isFloat: true, in: directory)
        let (pipeline, _) = await harness.make(local: file)
        await #expect(throws: ImagePipelineError.unsupportedImage) {
            try await pipeline.image(for: harness.key(), pixelBox: gridBox)
        }
    }

    @Test func sourcesOver4096PixelsAreRejected() async throws {
        let file = try TestImages.file(width: 4097, height: 16, in: directory)
        let (pipeline, _) = await harness.make(local: file)
        await #expect(throws: ImagePipelineError.tooLarge) {
            try await pipeline.image(for: harness.key(), pixelBox: gridBox)
        }
    }

    @Test func vanishedDownloadedCoverIsRefetchedOnce() async throws {
        let host = PipelineHarness.pngRoute()
        let missing = directory.appending(path: "deleted.jpg")
        let (pipeline, _) = await harness.make(host: host, local: missing)
        let image = try await pipeline.image(for: harness.key(), pixelBox: gridBox)
        #expect(image.pixelWidth > 0)
        #expect(ImageStubProtocol.route(host)?.requests.count == 1)
    }

    @Test func decodesWebP() async throws {
        let file = directory.appending(path: "cover.webp")
        try TestImages.webP.write(to: file)
        let (pipeline, _) = await harness.make(local: file)
        let image = try await pipeline.image(for: harness.key(), pixelBox: gridBox)
        #expect(image.pixelWidth == 1 && image.pixelHeight == 1)
    }
}

/// Returns one downloaded cover for every key, counting the lookups.
private final class CountingCovers: DownloadedCoverLookup {
    let file: URL
    let calls = Mutex(0)

    init(file: URL) {
        self.file = file
    }

    func downloadedCover(for key: ImageKey) async -> DownloadedCover? {
        calls.withLock { $0 += 1 }
        return DownloadedCover(fileURL: file, updatedAt: 1)
    }
}
