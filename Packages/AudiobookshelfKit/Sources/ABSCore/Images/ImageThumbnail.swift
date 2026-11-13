import CoreGraphics
import Foundation
import ImageIO

/// A downsampled image read from a local file, outside the ``ImagePipeline``, with the shared
/// decoder's source checks (ADR 0005, "Decoding"): the file's size, the source's dimensions and
/// its sample depth are checked before anything is decoded.
public enum ImageThumbnail {
    /// The image in `url`, downsampled so its long side is at most `maxPixelSize`.
    ///
    /// - Throws: ``ImagePipelineError/tooLarge`` for a file over 4 MiB or a source over
    ///   4096 × 4096 px, ``ImagePipelineError/unsupportedImage`` for one ImageIO can't decode or
    ///   with float or > 16-bit samples, and ``ImagePipelineError/fileMissing`` if it is gone.
    @concurrent
    public static func decode(contentsOf url: URL, maxPixelSize: Int) async throws -> CGImage {
        let info = try await ImageDecoder.inspect(url)
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw ImagePipelineError.fileMissing }
        let options =
            [
                kCGImageSourceThumbnailMaxPixelSize: min(max(maxPixelSize, 1), max(info.width, info.height)),
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw ImagePipelineError.unsupportedImage
        }
        return image
    }
}
