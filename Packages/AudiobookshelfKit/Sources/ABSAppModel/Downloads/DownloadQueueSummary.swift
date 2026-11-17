import ABSData
import Foundation

/// What the toolbar's download indicator shows (legacy `DownloadProgressIndicator.vue` in
/// `Appbar.vue`): the connection's downloads in progress — queued, downloading or paused — and
/// how far they are. Failed downloads aren't in progress; the Downloads tab lists them to retry.
/// Built from the same ``DownloadsListing`` downloads as the Downloading section.
public struct DownloadQueueSummary: Sendable, Equatable {
    /// The downloads in progress.
    public var count: Int
    /// How much of them is done, from 0 to 1, by bytes; 0 while no size is known.
    public var fraction: Double

    /// Whether the indicator shows: only while a download is in progress.
    public var isVisible: Bool { count > 0 }

    /// - Parameters: as ``DownloadsListing/init(items:records:progress:serverConnectionID:)``.
    public init(
        records: [DownloadRecordDTO], progress: [UUID: DownloadsController.Progress], serverConnectionID: UUID?
    ) {
        var listing = DownloadsListing(
            items: [], records: records, progress: progress, serverConnectionID: serverConnectionID)
        listing.downloads.removeAll { $0.status == .failed }
        count = listing.downloads.count
        fraction = listing.downloadingFraction
    }

    /// The summary of `controller`'s downloads for `serverConnectionID`.
    @MainActor
    public init(controller: DownloadsController, serverConnectionID: UUID?) {
        self.init(
            records: controller.records, progress: controller.progress, serverConnectionID: serverConnectionID)
    }
}
