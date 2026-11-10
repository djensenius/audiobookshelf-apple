#if os(macOS)
    import ABSCore
    import AppKit
    import CoreGraphics
    import Foundation
    import ImageIO
    import SwiftUI
    import Testing
    import UniformTypeIdentifiers

    @testable import ABSUI

    /// `PipelineImage` hosted in AppKit, to check what its first frame shows. The state tests
    /// can't tell whether SwiftUI applies a memory hit before that frame renders or after it.
    @MainActor @Suite struct PipelineImageHostingTests {
        /// Every cover is the same file.
        private struct LocalCovers: DownloadedCoverLookup {
            var file: URL

            func downloadedCover(for key: ImageKey) async -> DownloadedCover? {
                DownloadedCover(fileURL: file, updatedAt: key.updatedAt)
            }
        }

        /// A temporary folder, deleted when released.
        private final class Folder: Sendable {
            let url = FileManager.default.temporaryDirectory.appending(
                path: "PipelineImageHostingTests-\(UUID().uuidString)")

            init() throws {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }

            deinit {
                try? FileManager.default.removeItem(at: url)
            }
        }

        private let folder: Folder
        private let pipeline: ImagePipeline
        private let key = ImageKey(serverID: UUID(), kind: .itemCover, entityID: "li_1", updatedAt: 1)
        private let size = CGSize(width: 100, height: 160)
        private let scale = 2.0

        init() throws {
            folder = try Folder()
            let file = folder.url.appending(path: "cover.png")
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(
                CGContext(
                    data: nil, width: 200, height: 320, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 320))
            let destination = try #require(
                CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
            let image = try #require(context.makeImage())
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            pipeline = ImagePipeline(
                limits: .mac,
                fileStore: CoverFileStore(directory: folder.url.appending(path: "Images"), limit: 1 << 20),
                downloadedCovers: LocalCovers(file: file))
        }

        /// The colour at the centre of `view`'s first frame: it is laid out once, as AppKit does
        /// before drawing, without running the run loop or work queued on the main actor (such as
        /// a load resuming).
        private func firstFrameCentre(_ view: some View) throws -> NSColor {
            let host = NSHostingView(
                rootView: view.environment(\.imagePipeline, pipeline).environment(\.displayScale, scale))
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        }

        private func cover() -> some View {
            PipelineImage(key: key) {
                Color.green
            } failure: { _ in
                Color.blue
            }
        }

        private func expect(
            _ color: NSColor, matches expected: NSColor, sourceLocation: SourceLocation = #_sourceLocation
        ) throws {
            let actual = try #require(color.usingColorSpace(.sRGB))
            let wanted = try #require(expected.usingColorSpace(.sRGB))
            let distance =
                [
                    actual.redComponent - wanted.redComponent, actual.greenComponent - wanted.greenComponent,
                    actual.blueComponent - wanted.blueComponent, actual.alphaComponent - wanted.alphaComponent,
                ].map(abs).max() ?? 0
            #expect(distance < 0.02, "\(actual) isn't \(wanted)", sourceLocation: sourceLocation)
        }

        @Test func memoryHitIsOnTheFirstFrameAtFullOpacity() async throws {
            let request = try #require(ImageLoadRequest(key: key, size: size, scale: scale))
            let cached = try await pipeline.image(for: request.key, pixelBox: request.box)
            let reference = try firstFrameCentre(Image(decorative: cached.cgImage, scale: scale).resizable())
            try expect(try firstFrameCentre(cover()), matches: reference)
        }

        @Test func coldCacheShowsThePlaceholderOnTheFirstFrame() throws {
            try expect(try firstFrameCentre(cover()), matches: try firstFrameCentre(Color.green))
        }
    }
#endif
