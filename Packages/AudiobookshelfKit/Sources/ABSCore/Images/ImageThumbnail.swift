import CoreGraphics
import Foundation
import ImageIO

/// A downsampled image read from a local file, outside the ``ImagePipeline``, with the shared
/// decoder's source checks (ADR 0005, "Decoding"): the file's size, the source's dimensions and
/// its sample depth are checked before anything is decoded. The file is read once, into a bounded
/// snapshot, and the checks and the decode both use that snapshot, so a file replaced in between
/// can't skip them.
public enum ImageThumbnail {
    /// The image in `url`, downsampled so its long side is at most `maxPixelSize`.
    ///
    /// - Throws: ``ImagePipelineError/tooLarge`` for a file over 4 MiB or a source over
    ///   4096 × 4096 px, ``ImagePipelineError/unsupportedImage`` for one ImageIO can't decode or
    ///   with float or > 16-bit samples, and ``ImagePipelineError/fileMissing`` if it is gone.
    @concurrent
    public static func decode(contentsOf url: URL, maxPixelSize: Int) async throws -> CGImage {
        let data = try snapshot(of: url)
        try Task.checkCancellation()
        return try decode(data, url: url, maxPixelSize: maxPixelSize)
    }

    /// The file's bytes, reading at most one byte past ``ImageCacheLimits/maxInputBytes``.
    ///
    /// - Throws: ``ImagePipelineError/tooLarge`` if the file is over the cap.
    static func snapshot(of url: URL) throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw FileManager.default.fileExists(atPath: url.path) ? ImagePipelineError.unsupportedImage : .fileMissing
        }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: ImageCacheLimits.maxInputBytes + 1) ?? Data()
        } catch {
            throw ImagePipelineError.unsupportedImage
        }
        guard data.count <= ImageCacheLimits.maxInputBytes else { throw ImagePipelineError.tooLarge }
        return data
    }

    /// Checks and downsamples `data` (read from `url`) through one image source.
    static func decode(_ data: Data, url: URL, maxPixelSize: Int) throws -> CGImage {
        guard data.count <= ImageCacheLimits.maxInputBytes else { throw ImagePipelineError.tooLarge }
        guard
            let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw ImagePipelineError.unsupportedImage }
        let info = try ImageDecoder.inspect(source, url: url, unreadable: .unsupportedImage)
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
