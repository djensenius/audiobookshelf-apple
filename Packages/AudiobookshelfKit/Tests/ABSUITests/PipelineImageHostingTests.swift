#if os(macOS) || (canImport(UIKit) && !os(watchOS))
    import ABSCore
    import CoreGraphics
    import Foundation
    import ImageIO
    import SwiftUI
    import Testing
    import UniformTypeIdentifiers

    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    @testable import ABSUI

    /// `PipelineImage` hosted in AppKit or UIKit, to check what its first frame shows. The state
    /// tests can't tell whether SwiftUI applies a memory hit before that frame renders or after it.
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

        /// `view`'s first frame: it is laid out once, as AppKit and UIKit do before drawing,
        /// without running the run loop or work queued on the main actor (such as a load resuming).
        private func firstFrame(_ view: some View) throws -> CGImage {
            let root = view.environment(\.imagePipeline, pipeline).environment(\.displayScale, scale)
            #if os(macOS)
                let host = NSHostingView(rootView: root)
                host.frame = CGRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                return try #require(bitmap.cgImage)
            #else
                // Outside a window the hosting view draws nothing. Package tests run in `xctest`,
                // with no application or window scene, so the window needs the deprecated
                // `init(frame:)`.
                let controller = UIHostingController(rootView: root)
                let window = UIWindow(frame: CGRect(origin: .zero, size: size))
                window.rootViewController = controller
                window.isHidden = false
                defer { window.isHidden = true }
                controller.view.layoutIfNeeded()
                let format = UIGraphicsImageRendererFormat()
                format.scale = scale
                format.preferredRange = .standard
                let rendered = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
                    controller.view.layer.render(in: context.cgContext)
                }
                return try #require(rendered.cgImage)
            #endif
        }

        /// A colour in sRGB, premultiplied by alpha.
        private struct Pixel {
            var components: [Double]
        }

        /// The colour at the centre of `image`, drawn into one sRGB pixel.
        private func centre(of image: CGImage) throws -> Pixel {
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(
                CGContext(
                    data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .none
            let (width, height) = (CGFloat(image.width), CGFloat(image.height))
            context.draw(
                image,
                in: CGRect(
                    x: -(width / 2).rounded(.down), y: -(height / 2).rounded(.down), width: width, height: height))
            let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            return Pixel(components: (0..<4).map { Double(bytes[$0]) / 255 })
        }

        private func firstFrameCentre(_ view: some View) throws -> Pixel {
            try centre(of: try firstFrame(view))
        }

        private func cover() -> some View {
            PipelineImage(key: key) {
                Color.green
            } failure: { _ in
                Color.blue
            }
        }

        private func distance(_ pixel: Pixel, _ other: Pixel) -> Double {
            zip(pixel.components, other.components).map { abs($0 - $1) }.max() ?? 0
        }

        private func expect(
            _ pixel: Pixel, matches expected: Pixel, sourceLocation: SourceLocation = #_sourceLocation
        ) {
            #expect(distance(pixel, expected) < 0.02, "\(pixel) isn't \(expected)", sourceLocation: sourceLocation)
        }

        /// A capture that drew nothing would match any reference, so check that a reference
        /// differs from an empty view.
        private func expectDrawn(_ reference: Pixel, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let empty = try firstFrameCentre(Color.clear)
            #expect(distance(reference, empty) > 0.5, "\(reference) is empty", sourceLocation: sourceLocation)
        }

        @Test func memoryHitIsOnTheFirstFrameAtFullOpacity() async throws {
            let request = try #require(ImageLoadRequest(key: key, size: size, scale: scale))
            let cached = try await pipeline.image(for: request.key, pixelBox: request.box)
            let reference = try firstFrameCentre(Image(decorative: cached.cgImage, scale: scale).resizable())
            try expectDrawn(reference)
            expect(try firstFrameCentre(cover()), matches: reference)
        }

        @Test func coldCacheShowsThePlaceholderOnTheFirstFrame() throws {
            let placeholder = try firstFrameCentre(Color.green)
            try expectDrawn(placeholder)
            expect(try firstFrameCentre(cover()), matches: placeholder)
        }
    }
#endif
