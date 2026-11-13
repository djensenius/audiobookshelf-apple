import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import ABSCore

/// ``ImageThumbnail`` downsamples a local file, after the shared decoder's source checks.
struct ImageThumbnailTests {
    @Test func downsamplesTheImage() async throws {
        let directory = try TemporaryDirectory()
        let url = try TestImages.file(width: 600, height: 960, in: directory.url)

        let image = try await ImageThumbnail.decode(contentsOf: url, maxPixelSize: 96)

        #expect(max(image.width, image.height) == 96)
    }

    @Test func rejectsASourceOverTheDimensionLimit() async throws {
        let directory = try TemporaryDirectory()
        let url = try TestImages.file(width: ImageCacheLimits.maxSourceDimension + 1, height: 8, in: directory.url)

        await #expect(throws: ImagePipelineError.tooLarge) {
            try await ImageThumbnail.decode(contentsOf: url, maxPixelSize: 96)
        }
    }

    /// A decodable image padded past the input cap: only the size check rejects it.
    @Test func rejectsAFileOverTheInputCap() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "padded.png")
        var data = TestImages.data(width: 8, height: 8)
        data.append(Data(count: ImageCacheLimits.maxInputBytes + 1 - data.count))
        try data.write(to: url)

        await #expect(throws: ImagePipelineError.tooLarge) {
            try await ImageThumbnail.decode(contentsOf: url, maxPixelSize: 96)
        }
    }

    @Test func rejectsFloatSamples() async throws {
        let directory = try TemporaryDirectory()
        let url = try TestImages.file(
            width: 8, height: 8, type: .tiff, bitsPerComponent: 32, isFloat: true, in: directory.url)

        await #expect(throws: ImagePipelineError.unsupportedImage) {
            try await ImageThumbnail.decode(contentsOf: url, maxPixelSize: 96)
        }
    }

    /// The checks run on the bytes that are decoded, not on a separate read of the file.
    @Test func theSnapshotIsCheckedBeforeItIsDecoded() throws {
        let url = URL(filePath: "/unused/cover.png")
        let wide = TestImages.data(width: ImageCacheLimits.maxSourceDimension + 1, height: 8)
        #expect(throws: ImagePipelineError.tooLarge) {
            try ImageThumbnail.decode(wide, url: url, maxPixelSize: 96)
        }
        var padded = TestImages.data(width: 8, height: 8)
        padded.append(Data(count: ImageCacheLimits.maxInputBytes + 1 - padded.count))
        #expect(throws: ImagePipelineError.tooLarge) {
            try ImageThumbnail.decode(padded, url: url, maxPixelSize: 96)
        }
        let image = try ImageThumbnail.decode(TestImages.data(width: 600, height: 960), url: url, maxPixelSize: 96)
        #expect(max(image.width, image.height) == 96)
    }

    /// The snapshot stops one byte past the cap rather than reading the whole file.
    @Test func theSnapshotIsBounded() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "big.bin")
        try Data(count: ImageCacheLimits.maxInputBytes * 2).write(to: url)
        #expect(throws: ImagePipelineError.tooLarge) { try ImageThumbnail.snapshot(of: url) }

        let small = directory.url.appending(path: "small.bin")
        try Data(count: ImageCacheLimits.maxInputBytes).write(to: small)
        #expect(try ImageThumbnail.snapshot(of: small).count == ImageCacheLimits.maxInputBytes)
    }

    @Test func aMissingFileIsMissing() async throws {
        let directory = try TemporaryDirectory()

        await #expect(throws: ImagePipelineError.fileMissing) {
            try await ImageThumbnail.decode(contentsOf: directory.url.appending(path: "gone.png"), maxPixelSize: 96)
        }
    }
}
