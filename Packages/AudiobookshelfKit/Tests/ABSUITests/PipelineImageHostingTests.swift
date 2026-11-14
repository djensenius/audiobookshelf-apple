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
        /// `files` maps entity IDs to covers; every other cover is `file`.
        private struct LocalCovers: DownloadedCoverLookup {
            var file: URL
            var files: [String: URL] = [:]

            func downloadedCover(for key: ImageKey) async -> DownloadedCover? {
                DownloadedCover(fileURL: files[key.entityID] ?? file, updatedAt: key.updatedAt)
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
        /// A square cover and a book (1 : 1.6) one, red with a blue border a tenth of each side wide.
        private let squareKey = ImageKey(serverID: UUID(), kind: .itemCover, entityID: "li_square", updatedAt: 1)
        private let bookKey = ImageKey(serverID: UUID(), kind: .itemCover, entityID: "li_book", updatedAt: 1)
        private let size = CGSize(width: 100, height: 160)
        private let scale = 2.0

        init() throws {
            folder = try Folder()
            let file = folder.url.appending(path: "cover.png")
            try Self.writeCover(to: file, width: 200, height: 320, border: 0)
            let square = folder.url.appending(path: "square.png")
            try Self.writeCover(to: square, width: 300, height: 300, border: 30)
            let book = folder.url.appending(path: "book.png")
            try Self.writeCover(to: book, width: 300, height: 480, border: 48)
            pipeline = ImagePipeline(
                limits: .mac,
                fileStore: CoverFileStore(directory: folder.url.appending(path: "Images"), limit: 1 << 20),
                downloadedCovers: LocalCovers(
                    file: file, files: [squareKey.entityID: square, bookKey.entityID: book]))
        }

        /// A red PNG with a blue border `border` pixels wide.
        private static func writeCover(to file: URL, width: Int, height: Int, border: Int) throws {
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(
                CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(
                CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: CGFloat(border), dy: CGFloat(border)))
            let destination = try #require(
                CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
            let image = try #require(context.makeImage())
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }

        /// `view`'s first frame: it is laid out once, as AppKit and UIKit do before drawing,
        /// without running the run loop or work queued on the main actor (such as a load resuming).
        private func firstFrame(_ view: some View, size: CGSize? = nil) throws -> CGImage {
            let size = size ?? self.size
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

        /// The colour at `point` (from the top left) in `image`, drawn into one sRGB pixel.
        private func pixel(of image: CGImage, at point: UnitPoint = .center) throws -> Pixel {
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
                    x: -(width * point.x).rounded(.down), y: -(height * (1 - point.y)).rounded(.down), width: width,
                    height: height))
            let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            return Pixel(components: (0..<4).map { Double(bytes[$0]) / 255 })
        }

        private func firstFrameCentre(_ view: some View) throws -> Pixel {
            try pixel(of: try firstFrame(view))
        }

        private func cover(_ key: ImageKey? = nil) -> some View {
            PipelineImage(key: key ?? self.key) {
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

        /// A cover whose shape differs from its frame's shows whole, aspect-fit over a blurred
        /// fill of itself, rather than cropped to the frame (#626): a square cover's left and right
        /// edges show in a book frame, and a book cover's top and bottom edges in a square one.
        @Test(arguments: [
            (Mismatch.squareInBook, UnitPoint(x: 0.05, y: 0.5)), (.squareInBook, UnitPoint(x: 0.95, y: 0.5)),
            (.bookInSquare, UnitPoint(x: 0.5, y: 0.05)), (.bookInSquare, UnitPoint(x: 0.5, y: 0.95)),
        ])
        func coverOfAnotherShapeIsLetterboxedNotCropped(mismatch: Mismatch, edge: UnitPoint) async throws {
            let key = mismatch == .squareInBook ? squareKey : bookKey
            let size = mismatch == .squareInBook ? size : CGSize(width: 100, height: 100)
            // The real decode, cached so the first frame shows it.
            let request = try #require(ImageLoadRequest(key: key, size: size, scale: scale))
            let cached = try await pipeline.image(for: request.key, pixelBox: request.box)
            let fitted = try firstFrame(
                Image(decorative: cached.cgImage, scale: scale).resizable().scaledToFit(), size: size)
            let border = try pixel(of: fitted, at: edge)
            try expectDrawn(border)
            #expect(distance(border, try pixel(of: fitted)) > 0.5, "No border at \(edge)")

            let frame = try firstFrame(cover(key), size: size)
            expect(try pixel(of: frame, at: edge), matches: border)
            // The band beside the fitted cover shows its blurred fill, not the background.
            let band = mismatch == .squareInBook ? UnitPoint(x: 0.5, y: 0.03) : UnitPoint(x: 0.03, y: 0.5)
            let empty = try pixel(of: try firstFrame(Color.clear, size: size), at: band)
            expect(try pixel(of: fitted, at: band), matches: empty)
            #expect(distance(try pixel(of: frame, at: band), empty) > 0.5, "The band is empty")
        }

        /// How a cover's shape differs from its frame's.
        enum Mismatch: Sendable, CustomTestStringConvertible {
            case squareInBook, bookInSquare

            var testDescription: String {
                switch self {
                case .squareInBook: "square cover in a book frame"
                case .bookInSquare: "book cover in a square frame"
                }
            }
        }
    }
#endif
