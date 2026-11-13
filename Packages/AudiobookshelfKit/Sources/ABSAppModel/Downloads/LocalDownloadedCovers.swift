import ABSCore
import ABSData
import ABSDownloads
import Foundation

/// The image pipeline's ``DownloadedCoverLookup`` over the downloaded items in `LocalItemStore`
/// (ADR 0005, "Offline covers"). It reports a downloaded item's cover whatever its version; the
/// pipeline decides whether it is fresh enough.
public struct LocalDownloadedCovers: DownloadedCoverLookup {
    private let store: LocalItemStore
    private let locations: DownloadLocations

    public init(store: LocalItemStore, locations: DownloadLocations) {
        self.store = store
        self.locations = locations
    }

    public func downloadedCover(for key: ImageKey) async -> DownloadedCover? {
        guard key.kind == .itemCover,
            let item = try? await store.item(serverConnectionID: key.serverID, libraryItemId: key.entityID),
            let path = item.coverRelativePath, let url = try? locations.fileURL(forRelativePath: path),
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        else { return nil }
        return DownloadedCover(fileURL: url, updatedAt: Self.version(of: item.coverUpdatedAt))
    }

    /// The `updatedAt` a downloaded item's cover is keyed by (``CoverRef/updatedAt``): its
    /// `coverUpdatedAt` in milliseconds since 1970, or `nil` when unknown or out of `Int`'s range.
    public static func version(of coverUpdatedAt: Date?) -> Int? {
        coverUpdatedAt.flatMap { Int(exactly: ($0.timeIntervalSince1970 * 1000).rounded()) }
    }
}
