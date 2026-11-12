import Foundation

/// Identifies one version of one server image at one width bucket (ADR 0005).
///
/// A changed `updatedAt` produces a new key, so cached files and bitmaps never go stale; old
/// entries simply age out.
public struct ImageKey: Sendable, Hashable {
    /// The server connection's stable local UUID (not its address).
    public var serverID: UUID
    public var kind: ImageKind
    public var entityID: String
    /// The entity's `updatedAt` in epoch milliseconds.
    public var updatedAt: Int?
    /// The variant requested from the server. Views pick it from their rendered size.
    public var bucket: ImageWidthBucket
    /// An absolute `http(s)` cover URL (a legacy external `coverPath`) used instead of the
    /// server route. Local files come only from ``DownloadedCoverLookup``.
    public var externalURL: URL?

    public init(
        serverID: UUID, kind: ImageKind, entityID: String, updatedAt: Int?, bucket: ImageWidthBucket = .medium,
        externalURL: URL? = nil
    ) {
        self.serverID = serverID
        self.kind = kind
        self.entityID = entityID
        self.updatedAt = updatedAt
        self.bucket = bucket
        self.externalURL = externalURL
    }

    /// What the request builder loads for this key.
    public var source: ImageSource {
        if let externalURL { return .external(externalURL) }
        return .server(kind: kind, entityID: entityID, updatedAt: updatedAt, width: bucket)
    }

    public func with(bucket: ImageWidthBucket) -> ImageKey {
        var key = self
        key.bucket = bucket
        return key
    }

    func with(updatedAt: Int?) -> ImageKey {
        var key = self
        key.updatedAt = updatedAt
        return key
    }

    /// The `CoverFileStore` file name without its extension; see ``CoverLocator``.
    var fileStem: String { CoverLocator(self).fileStem }
}

/// The decoded size a consumer needs, in pixels. Each side is rounded up to a multiple of
/// 32 px and capped at 1200 px, so nearby sizes share one decode (ADR 0005).
public struct PixelBox: Sendable, Hashable {
    public let width: Int
    public let height: Int

    public init(width: Double, height: Double) {
        self.width = Self.rounded(width)
        self.height = Self.rounded(height)
    }

    /// The box for `size` points at `scale`.
    public init(size: CGSize, scale: Double) {
        self.init(width: size.width * scale, height: size.height * scale)
    }

    /// Larger than the iPhone grid box, so the decode must hold the large-decode slot.
    var isLarge: Bool { width * height > 512 * 832 }

    private static func rounded(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 32 }
        // Clamp before converting, so a huge finite value can't trap in `Int(_:)`.
        return min(Int((min(value, 1200) / 32).rounded(.up)) * 32, 1200)
    }
}

/// The key of a decoded bitmap: one fetched file can serve several boxes.
struct MemoryKey: Hashable, Sendable {
    var key: ImageKey
    var box: PixelBox
}

/// A downloaded item's cover file, from ``DownloadedCoverLookup``.
public struct DownloadedCover: Sendable, Hashable {
    public var fileURL: URL
    /// `LocalLibraryItem.coverUpdatedAt` in epoch milliseconds.
    public var updatedAt: Int?

    public init(fileURL: URL, updatedAt: Int?) {
        self.fileURL = fileURL
        self.updatedAt = updatedAt
    }
}

/// Finds the cover file of a downloaded item, so offline items show covers with no network.
/// Implemented by ABSAppModel's `LocalDownloadedCovers` over ABSData's `LocalItemStore`.
public protocol DownloadedCoverLookup: Sendable {
    /// The local cover for `key`'s entity, whatever its version, or `nil`.
    func downloadedCover(for key: ImageKey) async -> DownloadedCover?
}

/// Cache sizes and decode limits per device class (ADR 0005, "Cache sizes").
public struct ImageCacheLimits: Sendable, Hashable {
    /// The combined cap on the memory LRU and live ``CoverImage``s, in bytes.
    public var memoryBytes: Int
    /// The `CoverFileStore` cap, in bytes.
    public var diskBytes: Int
    /// Concurrent decodes; one of them may hold the large-decode slot.
    public var maxConcurrentDecodes: Int

    public init(memoryBytes: Int, diskBytes: Int, maxConcurrentDecodes: Int) {
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.maxConcurrentDecodes = max(1, maxConcurrentDecodes)
    }

    static let mebibyte = 1 << 20
    /// Encoded inputs over this size are rejected.
    static let maxInputBytes = 4 * mebibyte
    /// Sources wider or taller than this (the server's own clamp) are rejected.
    static let maxSourceDimension = 4096

    public static let iPhone = ImageCacheLimits(
        memoryBytes: 64 * mebibyte, diskBytes: 256 * mebibyte, maxConcurrentDecodes: 4)
    public static let iPad = ImageCacheLimits(
        memoryBytes: 128 * mebibyte, diskBytes: 256 * mebibyte,
        maxConcurrentDecodes: ProcessInfo.processInfo.activeProcessorCount)
    public static let mac = ImageCacheLimits(
        memoryBytes: 256 * mebibyte, diskBytes: 512 * mebibyte,
        maxConcurrentDecodes: ProcessInfo.processInfo.activeProcessorCount)
}
