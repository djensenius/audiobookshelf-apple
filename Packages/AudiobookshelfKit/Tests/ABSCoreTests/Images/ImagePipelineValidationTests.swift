import CoreGraphics
import Foundation
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

    @Test func nonImageSuccessIsNotCached() async throws {
        let host = ImageStubProtocol.register(.init(body: Data("<html>Sign in</html>".utf8), mimeType: "text/html"))
        let (pipeline, store) = await harness.make(host: host)
        await #expect(throws: ImagePipelineError.unsupportedImage) {
            try await pipeline.image(for: harness.key(), pixelBox: gridBox)
        }
        #expect(await store.size == 0)
    }

    @Test func undecodableStoredFileIsDeleted() async throws {
        let (pipeline, store) = await harness.make(isOnline: { false })
        let key = harness.key()
        let file = store.directory.appending(path: "\(key.serverID.uuidString)/\(key.fileStem).webp")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: file)
        await #expect(throws: ImagePipelineError.unsupportedImage) {
            try await pipeline.image(for: key, pixelBox: gridBox)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
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
        await #expect(throws: (any Error).self) { try await loading.value }
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

    @Test func sixteenBitSourcesAreNormalizedToEightBit() async throws {
        let file = try TestImages.file(width: 600, height: 960, bitsPerComponent: 16, in: directory)
        let (pipeline, _) = await harness.make(local: file)
        let image = try await pipeline.image(for: harness.key(), pixelBox: gridBox)
        #expect(image.cgImage.bitsPerComponent == 8)
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
