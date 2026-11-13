import ABSCore
import ABSData
import ABSDownloads
import Foundation
import Observation

/// What the Downloads tab is built from; the app builds one over its download stack.
@MainActor
public struct DownloadsServices {
    public let controller: DownloadsController
    public let control: any DownloadControlling
    /// A connection's downloaded items after every write, as the writer's
    /// `LocalItemStore.updates(serverConnectionID:)` streams them, or `nil`. With it, every
    /// ``DownloadsTabModel`` reads the items again after any change, a deletion in another window
    /// included; without it, only after its own deletions and completed downloads.
    public let localItemUpdates: (@Sendable (UUID) async throws -> AsyncStream<[LocalLibraryItemDTO]>)?
    /// A connection's downloaded items, as `LocalItemStore.items(serverConnectionID:)` reads them.
    public let localItems: @Sendable (UUID) async throws -> [LocalLibraryItemDTO]
    /// One downloaded item, as `LocalItemStore.item(id:)` reads it; `nil` once it's deleted.
    public let localItem: @Sendable (UUID) async throws -> LocalLibraryItemDTO?
    /// The file a downloaded item's relative path names, as `DownloadLocations.fileURL(forRelativePath:)`
    /// resolves it; `nil` for an invalid path.
    public let localFileURL: @Sendable (String) -> URL?
    /// The bytes still available for downloads, as ``StorageCapacityProviding`` reports them.
    public let availableCapacity: @Sendable () async throws -> Int64

    public init(
        controller: DownloadsController, control: any DownloadControlling,
        localItemUpdates: (@Sendable (UUID) async throws -> AsyncStream<[LocalLibraryItemDTO]>)? = nil,
        localItems: @escaping @Sendable (UUID) async throws -> [LocalLibraryItemDTO],
        localItem: @escaping @Sendable (UUID) async throws -> LocalLibraryItemDTO? = { _ in nil },
        localFileURL: @escaping @Sendable (String) -> URL? = { _ in nil },
        availableCapacity: @escaping @Sendable () async throws -> Int64
    ) {
        self.controller = controller
        self.control = control
        self.localItemUpdates = localItemUpdates
        self.localItems = localItems
        self.localItem = localItem
        self.localFileURL = localFileURL
        self.availableCapacity = availableCapacity
    }
}

/// The Downloads tab's state and actions for the signed-in connection (#75): its
/// ``DownloadsListing``, the free space, and cancelling, retrying and deleting.
///
/// - ``observe(connectionID:)`` reads the downloaded items, then reads them again after every
///   write to the store (``DownloadsServices/localItemUpdates``), so a finished download moves
///   from Downloading to the list, and a deletion in another window leaves this one too. Without
///   those updates it reads them again whenever a download completes.
/// - ``reload()`` also reads the stored downloads under way again if they couldn't be read
///   (``queueLoadError``).
/// - A retry the user starts goes through the download cellular policy, like a new request
///   (``DownloadsController/request(item:episodeID:connectionID:)``): on a metered path,
///   ``CellularPolicy/ask`` sets ``Notice/confirmMeteredRetry(_:)`` and
///   ``CellularPolicy/never`` sets ``Notice/retryDenied``, and nothing is retried until
///   ``confirmMeteredRetry(recordID:)``.
/// - A failed action sets ``notice``; the view shows it and clears it.
@MainActor
@Observable
public final class DownloadsTabModel {
    /// Something the view tells the user about an action.
    public enum Notice: Sendable, Equatable {
        case cancelFailed
        case retryFailed
        /// The download cellular policy doesn't allow downloads on the current path.
        case retryDenied
        /// The path is metered and the policy is ``CellularPolicy/ask``: ask, then call
        /// ``confirmMeteredRetry(recordID:)``.
        case confirmMeteredRetry(UUID)
        case deleteFailed
    }

    /// The connection's downloaded items, as last read.
    public private(set) var items: [LocalLibraryItemDTO] = []
    /// Whether the items were read at least once.
    public private(set) var isLoaded = false
    /// Why the last read failed, or `nil`.
    public private(set) var loadError: (any Error)?
    /// Why the stored downloads under way couldn't be read (``DownloadsController/loadError``),
    /// or `nil`; only the downloads whose events arrived since are listed. ``reload()`` reads
    /// them again.
    public var queueLoadError: (any Error)? { services.controller.loadError }
    /// The bytes the listed books and podcasts use, or `nil` until a read of them succeeds: after
    /// a failed one (``loadError``), the items listed are those of an earlier read, or none.
    public var downloadedBytes: Int64? { isLoaded && loadError == nil ? listing.downloadedBytes : nil }
    /// The bytes still available for downloads, or `nil` while unknown.
    public private(set) var availableBytes: Int64?
    public var notice: Notice?
    /// The records and local items with an action under way, whose controls are disabled.
    public private(set) var busy: Set<UUID> = []
    public private(set) var connectionID: UUID?

    @ObservationIgnored private let services: DownloadsServices
    /// Counts reads, so an older one finishing late doesn't replace a newer one.
    @ObservationIgnored private var readGeneration = 0
    /// Tests: called after each ``reload()`` that applied its result.
    @ObservationIgnored var reloaded: (@MainActor () -> Void)?

    public init(services: DownloadsServices) {
        self.services = services
    }

    /// The items, downloads and sizes to show.
    public var listing: DownloadsListing {
        DownloadsListing(
            items: items, records: services.controller.records, progress: services.controller.progress,
            serverConnectionID: connectionID)
    }

    // MARK: - Loading

    /// Reads the items of `connectionID`, then again after every write to the store (or, without
    /// ``DownloadsServices/localItemUpdates``, every completed download), until the task is
    /// cancelled.
    public func observe(connectionID: UUID?) async {
        if self.connectionID != connectionID {
            self.connectionID = connectionID
            items = []
            loadError = nil
            isLoaded = false
        }
        // Its first snapshot is the items as they are, so it is read once, then again after
        // every write: a completed download, or a deletion in any window.
        if let connectionID, let updates = try? await services.localItemUpdates?(connectionID) {
            for await _ in updates { await reload() }
            return
        }
        // Subscribed before the read, so a completion during it is followed by another read.
        let events = await services.control.events()
        await reload()
        for await event in events {
            if case .completed = event { await reload() }
        }
    }

    /// Reads the items and the free space again, and the stored downloads under way if they
    /// couldn't be read (``queueLoadError``).
    public func reload() async {
        readGeneration += 1
        let generation = readGeneration
        await services.controller.retryLoadingStoredRecords()
        guard let connectionID else {
            items = []
            isLoaded = true
            reloaded?()
            return
        }
        let read = services.localItems
        let capacity = services.availableCapacity
        let result: Result<[LocalLibraryItemDTO], any Error>
        do {
            result = .success(try await read(connectionID))
        } catch {
            result = .failure(error)
        }
        let available = try? await capacity()
        guard generation == readGeneration, connectionID == self.connectionID else { return }
        switch result {
        case .success(let fresh):
            items = fresh
            loadError = nil
        case .failure(let error):
            loadError = error
            Log.downloads.error(
                "Couldn't read the downloaded items: \(Log.redact(String(describing: error)), privacy: .public)")
        }
        availableBytes = available
        isLoaded = true
        reloaded?()
    }

    // MARK: - Downloads under way

    public func cancel(recordID: UUID) async {
        await perform(on: recordID, failure: .cancelFailed) { try await $0.cancel(recordID: recordID) }
    }

    /// Cancels every listed download, oldest first; one that fails doesn't stop the others.
    public func cancelAll() async {
        for download in listing.downloads {
            await cancel(recordID: download.id)
        }
    }

    /// Retries a paused or failed download if the download cellular policy allows it on the
    /// current path (waiting up to the controller's path timeout for the first path).
    public func retry(recordID: UUID) async {
        switch await services.controller.gate(waitingForPath: true) {
        case .allowed: await performRetry(recordID)
        case .askUser: notice = .confirmMeteredRetry(recordID)
        case .denied: notice = .retryDenied
        }
    }

    /// Retries a download the user agreed to after ``Notice/confirmMeteredRetry(_:)``; denied
    /// instead if the policy became ``CellularPolicy/never`` while they decided.
    public func confirmMeteredRetry(recordID: UUID) async {
        if case .denied = await services.controller.gate(waitingForPath: false) {
            notice = .retryDenied
            return
        }
        await performRetry(recordID)
    }

    private func performRetry(_ recordID: UUID) async {
        await perform(on: recordID, failure: .retryFailed) { try await $0.retry(recordID: recordID) }
    }

    // MARK: - Downloaded media

    /// Deletes a downloaded item with all its files.
    public func delete(itemID: UUID) async {
        await perform(on: itemID, failure: .deleteFailed) { try await $0.deleteLocalItem(id: itemID) }
        await reload()
    }

    /// Deletes one downloaded podcast episode; the podcast goes with its last episode.
    public func deleteEpisode(itemID: UUID, episodeId: String) async {
        await perform(on: itemID, failure: .deleteFailed) {
            try await $0.deleteEpisode(itemID: itemID, episodeId: episodeId)
        }
        await reload()
    }

    /// Runs `action` with `id` marked busy. `false` (the record or item is gone already) isn't
    /// a failure: the list catches up.
    private func perform(
        on id: UUID, failure: Notice,
        _ action: @Sendable (any DownloadControlling) async throws -> Bool
    ) async {
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            _ = try await action(services.control)
        } catch {
            notice = failure
            Log.downloads.error(
                "A download action failed: \(Log.redact(String(describing: error)), privacy: .public)")
        }
    }
}
