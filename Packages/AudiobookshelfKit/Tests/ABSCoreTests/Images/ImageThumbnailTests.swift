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

    @Test func aMissingFileIsMissing() async throws {
        let directory = try TemporaryDirectory()

        await #expect(throws: ImagePipelineError.fileMissing) {
            try await ImageThumbnail.decode(contentsOf: directory.url.appending(path: "gone.png"), maxPixelSize: 96)
        }
    }
}
