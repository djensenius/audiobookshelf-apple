import ABSCore
import Foundation
import Observation

/// CarPlay's Downloads tab (#80) for one signed-in account: its downloaded books and episodes
/// (``CarPlayContentBuilder/downloads(_:offset:)``), played from their files.
///
/// It follows the local item store through a ``DownloadedShelfModel`` of its own, as Home's
/// Downloaded shelf does, so a completed or deleted download changes ``list(offset:)`` without a
/// reload. It needs no server: the store is local, and a tapped row plays through
/// ``CarPlayRootModel/play(_:offset:of:)``, whose play action plays a download from its files
/// without the streaming policy's metered-network prompt (#74).
///
/// A model belongs to one account: the CarPlay delegate creates one per ``SessionIdentity``, runs
/// ``observe()`` while it's shown, and replaces it when the account changes or drops it when
/// signed out.
@MainActor
@Observable
public final class CarPlayDownloadsModel {
    public let identity: SessionIdentity
    private let shelf: DownloadedShelfModel
    @ObservationIgnored private let builder: CarPlayContentBuilder

    /// - Parameters:
    ///   - updates: The local item store's snapshots of a connection's items
    ///     (``DownloadsServices/localItemUpdates``).
    ///   - limits: The car's list limits (``CarPlayLimits``).
    ///   - imageBucket: The width bucket of row images (``CarPlayContentBuilder/imageBucket``).
    public init(
        identity: SessionIdentity, updates: @escaping DownloadedShelfModel.Updates, limits: CarPlayLimits = .standard,
        labels: CarPlayLabels, imageBucket: ImageWidthBucket = .small
    ) {
        self.identity = identity
        shelf = DownloadedShelfModel(updates: updates)
        builder = CarPlayContentBuilder(
            limits: limits, labels: labels, serverID: identity.connectionID, imageBucket: imageBucket)
    }

    /// Follows the account's downloaded items until the calling task is cancelled.
    public func observe() async {
        await shelf.observe(connectionID: identity.connectionID)
    }

    /// Reads the items again after they couldn't be, for example when the tab shows again;
    /// nothing while they're followed.
    public func retry() {
        shelf.retry()
    }

    /// The page of the tab's list from `offset`: books, then episodes.
    public func list(offset: Int = 0) -> CarPlayList {
        builder.downloads(shelf.books + shelf.podcasts, offset: offset)
    }

    /// Whether the items have been read, for the message an empty list shows.
    public var status: CarPlayBrowseStatus {
        guard shelf.isLoaded else { return .loading }
        return shelf.loadError == nil ? .loaded : .failed
    }

    /// Whether `row` is shown, and enabled, on the page from `offset`: a tap from a page that has
    /// changed since, such as a deleted download's row, is ignored.
    public func shows(_ row: CarPlayRow, offset: Int) -> Bool {
        list(offset: offset).rows.contains {
            $0.id == row.id && $0.action == row.action && $0.image == row.image && $0.isEnabled
        }
    }

    /// The offset to show the list from after its items changed: `offset`, unless the page from
    /// it is now empty, with no "More…" to leave it (its downloads were deleted); then the first
    /// page.
    public func offset(afterChangeFrom offset: Int) -> Int {
        guard offset > 0, list(offset: offset).rows.isEmpty else { return offset }
        return 0
    }
}
