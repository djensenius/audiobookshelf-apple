import ABSCore
import ABSData
import ABSDownloads
import Foundation
import Observation

/// One connection's downloaded items, read once for a whole screen of Download buttons (#75), such
/// as a podcast's episode rows: every row's ``ItemDownloadModel`` reads ``items`` instead of
/// observing the store itself, so a list follows the store with one subscription, not one per row.
///
/// - ``observe()`` follows the store's snapshots (``DownloadsServices/localItemUpdates``), or
///   without them reads the items, then again after every completed download.
/// - With a `libraryItemID`, only that server item's local items are kept, so a write to another
///   item's download doesn't redraw the rows.
///
/// A feed belongs to one connection and server item: screens recreate it when either changes.
@MainActor
@Observable
public final class DownloadedItemsFeed {
    public let connectionID: UUID
    /// The server item whose local items are kept, or `nil` for all of the connection's.
    public let libraryItemID: String?
    /// The connection's downloaded items (of ``libraryItemID`` when set), as last read.
    public private(set) var items: [LocalLibraryItemDTO] = []

    @ObservationIgnored private let services: DownloadsServices
    @ObservationIgnored private var readGeneration = 0
    /// Tests: called after each read or snapshot that applied its result.
    @ObservationIgnored var reloaded: (@MainActor () -> Void)?

    public init(connectionID: UUID, libraryItemID: String? = nil, services: DownloadsServices) {
        self.connectionID = connectionID
        self.libraryItemID = libraryItemID
        self.services = services
    }

    /// Follows the store's snapshots of the connection's items or, without
    /// ``DownloadsServices/localItemUpdates``, reads them now and after every completed download,
    /// until the task is cancelled.
    public func observe() async {
        if let updates = try? await services.localItemUpdates?(connectionID) {
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                // A read under way is older than this snapshot.
                readGeneration += 1
                apply(snapshot)
            }
            return
        }
        // Subscribed before the read, so a completion during it is followed by another read.
        let events = await services.control.events()
        await reload()
        for await event in events {
            if case .completed = event { await reload() }
        }
    }

    /// Reads the connection's items again. A failed read keeps the last one.
    public func reload() async {
        readGeneration += 1
        let generation = readGeneration
        let read = services.localItems
        let connectionID = connectionID
        let result: Result<[LocalLibraryItemDTO], any Error>
        do {
            result = .success(try await read(connectionID))
        } catch {
            result = .failure(error)
        }
        guard generation == readGeneration else { return }
        switch result {
        case .success(let items):
            apply(items)
        case .failure(let error):
            Log.downloads.error(
                "Couldn't read the downloaded items: \(Log.redact(String(describing: error)), privacy: .public)")
            reloaded?()
        }
    }

    private func apply(_ snapshot: [LocalLibraryItemDTO]) {
        let kept = snapshot.filter { item in
            item.serverConnectionID == connectionID && (libraryItemID.map { item.libraryItemId == $0 } ?? true)
        }
        // Unchanged items leave the rows alone.
        if kept != items { items = kept }
        reloaded?()
    }
}
