import CoreGraphics
import Foundation
import ImageIO

/// Why an image couldn't be loaded. Every case shows the placeholder.
public enum ImagePipelineError: Error, Sendable, Equatable {
    /// No request could be built (no builder for the server, or an invalid URL).
    case noRequest
    /// The server (or a proxy, for 401 and 403) answered with this status.
    case httpStatus(Int)
    /// The encoded input is over 4 MiB, or the source over 4096 × 4096 px.
    case tooLarge
    /// ImageIO can't decode the input, or it has float or > 16-bit samples.
    case unsupportedImage
    /// The input file vanished before it was decoded.
    case fileMissing
    /// Offline, with no downloaded or cached file.
    case offline
}

/// Downsampling decode with ImageIO (ADR 0005, "Decoding"). Every function runs off the
/// pipeline actor.
enum ImageDecoder {
    struct SourceInfo: Sendable {
        var url: URL
        /// The size after applying the EXIF orientation.
        var width: Int
        var height: Int
        var depth: Int
        var isRGB: Bool

        /// Whether the decode is likely to need normalizing, so it must take the large slot up
        /// front.
        var needsNormalizing: Bool { depth > 8 || !isRGB }
    }

    @concurrent static func inspect(_ url: URL) async throws -> SourceInfo {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            throw FileManager.default.fileExists(atPath: url.path) ? ImagePipelineError.unsupportedImage : .fileMissing
        }
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else {
            throw FileManager.default.fileExists(atPath: url.path) ? ImagePipelineError.unsupportedImage : .fileMissing
        }
        let limit = ImageCacheLimits.maxSourceDimension
        guard width <= limit, height <= limit else { throw ImagePipelineError.tooLarge }
        let depth = properties[kCGImagePropertyDepth] as? Int ?? 8
        let isFloat = properties[kCGImagePropertyIsFloat] as? Bool ?? false
        guard !isFloat, depth <= 16 else { throw ImagePipelineError.unsupportedImage }
        let model = properties[kCGImagePropertyColorModel] as? String
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let swapsSides = (5...8).contains(orientation)
        return SourceInfo(
            url: url, width: swapsSides ? height : width, height: swapsSides ? width : height, depth: depth,
            isRGB: model == nil || model == (kCGImagePropertyColorModelRGB as String))
    }

    /// Whether ImageIO recognises the file's format.
    @concurrent static func isImage(_ url: URL) async -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return false }
        return CGImageSourceGetType(source) != nil
    }

    /// The long side of the source aspect-fitted into `box`, never larger than the source or
    /// wider than the requested bucket.
    static func maxPixelSize(width: Int, height: Int, box: PixelBox, bucket: ImageWidthBucket) -> Int {
        let fit = min(Double(box.width) / Double(width), Double(box.height) / Double(height))
        let scale = min(fit, Double(bucket.rawValue) / Double(width), 1)
        return max(1, Int((Double(max(width, height)) * scale).rounded()))
    }

    /// A bound on the decoded bytes, including up to 64 B of row padding, for reserving room.
    static func estimatedCost(of info: SourceInfo, box: PixelBox, bucket: ImageWidthBucket) -> Int {
        let long = maxPixelSize(width: info.width, height: info.height, box: box, bucket: bucket)
        let scale = Double(long) / Double(max(info.width, info.height))
        let width = Int((Double(info.width) * scale).rounded(.up)) + 1
        let height = Int((Double(info.height) * scale).rounded(.up)) + 1
        return (width * 4 + 64) * height
    }

    @concurrent static func decode(_ info: SourceInfo, box: PixelBox, bucket: ImageWidthBucket) async throws -> CGImage
    {
        try Task.checkCancellation()
        guard
            let source = CGImageSourceCreateWithURL(
                info.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw ImagePipelineError.fileMissing }
        let options =
            [
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize(
                    width: info.width, height: info.height, box: box, bucket: bucket),
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw ImagePipelineError.unsupportedImage
        }
        return image
    }

    /// Whether `image` isn't 8-bit premultiplied (or opaque "skip") RGB in a standard layout:
    /// alpha-first as BGRA (little-endian) or ARGB (the default order, which is what ImageIO's
    /// thumbnails use for JPEG and PNG), or alpha-last as RGBA. Anything else (such as ABGR) is
    /// redrawn.
    static func needsNormalizing(_ image: CGImage) -> Bool {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.colorSpace?.model == .rgb else {
            return true
        }
        let order = image.byteOrderInfo
        switch image.alphaInfo {
        case .premultipliedFirst, .noneSkipFirst: return ![.order32Little, .orderDefault, .order32Big].contains(order)
        case .premultipliedLast, .noneSkipLast: return order != .orderDefault && order != .order32Big
        default: return true
        }
    }

    /// Redraws `image` into an 8-bit premultiplied context, in Display P3 for wide-gamut
    /// sources and sRGB otherwise.
    @concurrent static func normalize(_ image: CGImage) async throws -> CGImage {
        try Task.checkCancellation()
        let isWide = image.colorSpace?.isWideGamutRGB ?? false
        guard
            let space = CGColorSpace(name: isWide ? CGColorSpace.displayP3 : CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw ImagePipelineError.unsupportedImage }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let normalized = context.makeImage() else { throw ImagePipelineError.unsupportedImage }
        return normalized
    }
}
