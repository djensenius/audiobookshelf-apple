import ABSCore
import ABSData
import ABSDownloads
import Foundation
import Observation

/// One book's, or one podcast episode's, Download button (#75): its ``ItemDownloadState`` and
/// starting, retrying, cancelling and deleting its download. A port of the legacy book page's
/// `downloadClick` (`pages/item/_id/index.vue`), which on iOS starts the download without asking
/// unless the path is metered.
///
/// - ``state`` follows ``DownloadsController``'s records and progress as they change, and the
///   connection's downloaded items, which ``observe()`` reads again after every write to the
///   store (``DownloadsServices/localItemUpdates``), or without those updates after every
///   completed download.
/// - ``download(item:)`` queues the download through ``DownloadRequesting``, which applies the
///   download cellular policy: on a metered path, ``CellularPolicy/ask`` sets
///   ``Prompt/meteredConfirmation`` and ``confirmMetered()`` queues it once the user agrees;
///   ``CellularPolicy/never`` sets ``Prompt/meteredDenied``. On a paused or failed download it
///   resumes it, through the same check. A request refused because the session ended or the user
///   may not download (``DownloadRequestOutcome/rejected(_:)``) is dropped without a prompt.
/// - ``cancel()`` removes the download under way; ``delete()`` removes the downloaded files. The
///   view asks before deleting.
/// - A failed action sets ``prompt``; the view shows it and clears it.
///
/// A list of rows (a podcast's episodes) shares one ``DownloadedItemsFeed`` instead: each row's
/// model reads the feed's items, and the screen observes the feed once.
///
/// A model belongs to one server item, episode, connection and feed: views recreate it when any
/// of them changes.
@MainActor
@Observable
public final class ItemDownloadModel {
    /// What the view asks or tells the user.
    public enum Prompt: Sendable, Hashable {
        /// Download using cellular data? (`MessageConfirmDownloadUsingCellular`)
        case meteredConfirmation
        /// The download cellular policy doesn't allow it (`ToastDownloadNotAllowedOnCellular`).
        case meteredDenied
        /// The device hasn't enough free space for the download.
        case notEnoughSpace
        /// The download couldn't be queued.
        case startFailed
        case cancelFailed
        case deleteFailed
    }

    public let libraryItemID: String
    /// The podcast episode, or `nil` for a book.
    public let episodeID: String?
    public let connectionID: UUID
    /// A request, cancel or delete is under way; the view disables the button.
    public private(set) var isWorking = false
    /// Set the view's alert from it; the view clears it when the alert closes.
    public var prompt: Prompt?
    /// The connection's downloaded items of this server item, as last read (by the feed, when
    /// shared).
    public var localItems: [LocalLibraryItemDTO] {
        guard let feed else { return ownItems }
        return feed.items.filter { $0.libraryItemId == libraryItemID }
    }
    /// The shared feed the local items come from, or `nil` when the model reads them itself.
    public let feed: DownloadedItemsFeed?
    /// The local items the model read itself, without a feed.
    private var ownItems: [LocalLibraryItemDTO] = []

    @ObservationIgnored private let access: DownloadAccess
    @ObservationIgnored private let services: DownloadsServices
    @ObservationIgnored private var readGeneration = 0
    /// The item and request that asked for ``Prompt/meteredConfirmation``.
    @ObservationIgnored private var pendingMetered: (item: LibraryItem, ticket: DownloadRequestTicket)?
    /// Tests: called after each read of the local items that applied its result.
    @ObservationIgnored var reloaded: (@MainActor () -> Void)?

    /// - Parameter feed: the screen's shared local items, of the same connection; `nil` to read
    ///   them in ``observe()``.
    public init(
        libraryItemID: String, episodeID: String? = nil, connectionID: UUID, access: DownloadAccess,
        services: DownloadsServices, feed: DownloadedItemsFeed? = nil
    ) {
        self.libraryItemID = libraryItemID
        self.episodeID = episodeID
        self.connectionID = connectionID
        self.feed = feed
        self.access = access
        self.services = services
    }

    /// The media's download state now.
    public var state: ItemDownloadState {
        ItemDownloadState(
            libraryItemID: libraryItemID, episodeID: episodeID, connectionID: connectionID,
            records: services.controller.records, progress: services.controller.progress,
            localItems: feed?.items ?? ownItems)
    }

    /// Whether a download may be requested now: the connection's session is running and its user
    /// may download (``DownloadRequesting/canRequest(connectionID:)``). Offline, or for another
    /// account, it's `false`; the view then shows a Download it can't start, while cancelling and
    /// deleting stay available.
    public var canRequest: Bool { access.requester.canRequest(connectionID: connectionID) }

    /// Whether the view shows the button: a download can be requested, or there is one under way
    /// or downloaded to cancel or delete. Legacy hides Download without the permission
    /// (`userCanDownload`), and offline.
    public var isShown: Bool { canRequest || !state.canStart }

    // MARK: - Loading

    /// Reads the connection's downloaded items, then again after every write to the store (or,
    /// without ``DownloadsServices/localItemUpdates``, every completed download), until the task
    /// is cancelled. With a ``feed``, returns at once: the screen observes the feed.
    public func observe() async {
        guard feed == nil else { return }
        if let updates = try? await services.localItemUpdates?(connectionID) {
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

    /// Reads the connection's downloaded items again (through the ``feed``, when shared). A failed
    /// read keeps the last one.
    public func reload() async {
        if let feed {
            await feed.reload()
            reloaded?()
            return
        }
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
            ownItems = items.filter { $0.libraryItemId == libraryItemID }
        case .failure(let error):
            Log.downloads.error(
                "Couldn't read the downloaded items: \(Log.redact(String(describing: error)), privacy: .public)")
        }
        reloaded?()
    }

    // MARK: - Actions

    /// Queues the download of `item` (expanded, `ItemEndpoints.item(id:)`), or resumes a paused
    /// or failed one. Does nothing for another server item, while queued, downloading or
    /// downloaded, or when ``canRequest`` is `false`.
    public func download(item: LibraryItem) async {
        let state = state
        guard !isWorking, item.id == libraryItemID, state.canStart || state.canRetry, canRequest else { return }
        isWorking = true
        defer { isWorking = false }
        pendingMetered = nil
        await handle(await access.requester.request(item: item, episodeID: episodeID, connectionID: connectionID), item)
    }

    /// Queues the download the user agreed to after ``Prompt/meteredConfirmation``.
    public func confirmMetered() async {
        guard !isWorking, let pending = pendingMetered else { return }
        pendingMetered = nil
        isWorking = true
        defer { isWorking = false }
        await handle(
            await access.requester.confirmMeteredDownload(
                item: pending.item, episodeID: episodeID, ticket: pending.ticket),
            pending.item)
    }

    /// Drops the request that asked for ``Prompt/meteredConfirmation``.
    public func dismissMetered() {
        pendingMetered = nil
    }

    private func handle(_ outcome: DownloadRequestOutcome, _ item: LibraryItem) async {
        switch outcome {
        case .started(.alreadyDownloaded):
            // Downloaded meanwhile, perhaps in another window.
            await reload()
        case .started:
            // The record's events update the state.
            break
        case .needsConfirmation(_, let ticket):
            pendingMetered = (item, ticket)
            prompt = .meteredConfirmation
        case .denied:
            prompt = .meteredDenied
        case .rejected:
            // The account the request was for is gone, or may not download: nothing to tell.
            break
        case .failed(let error):
            Log.downloads.error(
                "Couldn't queue a download: \(Log.redact(String(describing: error)), privacy: .public)")
            if case .insufficientStorage = error { prompt = .notEnoughSpace } else { prompt = .startFailed }
        }
    }

    /// Cancels the download under way, removing its record and partial files.
    public func cancel() async {
        guard let recordID = state.recordID else { return }
        await perform(failure: .cancelFailed) { try await $0.cancel(recordID: recordID) }
    }

    /// Deletes the downloaded book with its files, or the downloaded episode (the podcast goes
    /// with its last one).
    public func delete() async {
        guard let localItemID = state.localItemID else { return }
        if let episodeID {
            await perform(failure: .deleteFailed) {
                try await $0.deleteEpisode(itemID: localItemID, episodeId: episodeID)
            }
        } else {
            await perform(failure: .deleteFailed) { try await $0.deleteLocalItem(id: localItemID) }
        }
        await reload()
    }

    /// Runs `action` with ``isWorking`` set. `false` (already gone) isn't a failure.
    private func perform(
        failure: Prompt, _ action: @Sendable (any DownloadControlling) async throws -> Bool
    ) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await action(services.control)
        } catch {
            prompt = failure
            Log.downloads.error(
                "A download action failed: \(Log.redact(String(describing: error)), privacy: .public)")
        }
    }
}
