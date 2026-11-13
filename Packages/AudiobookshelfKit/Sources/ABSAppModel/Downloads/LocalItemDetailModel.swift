import ABSCore
import ABSData
import ABSDownloads
import CoreGraphics
import Foundation
import Observation

/// The local item screen's state and actions (#75): reads one downloaded item, shows it as a
/// ``LocalItemDetail`` for the signed-in account, and deletes it or one of its podcast episodes.
///
/// - ``observe()`` reads the item, then again after every write to its connection's downloads
///   (a deletion in another window, another episode arriving), or, without those updates,
///   whenever a download of the same server item completes.
/// - Deleting the item, or its last episode, sets ``isDeleted``; the view then leaves.
/// - A failed delete sets ``notice``; the view shows it and clears it.
/// - ``coverFileURL`` is the downloaded cover, which the view shows itself, so it appears offline
///   even after the image cache dropped it.
@MainActor
@Observable
public final class LocalItemDetailModel {
    /// A failure to tell the user about.
    public enum Notice: Sendable, Equatable {
        case deleteFailed
    }

    public let itemID: UUID
    public private(set) var item: LocalLibraryItemDTO?
    public private(set) var isLoaded = false
    public private(set) var loadError: (any Error)?
    /// The item is gone: deleted here, or elsewhere meanwhile.
    public private(set) var isDeleted = false
    public var notice: Notice?
    /// An item or episode delete is under way.
    public private(set) var isDeleting = false
    /// The signed-in account, for ``LocalItemDetail/link``; `nil` while signed out.
    public var account: LocalItemDetail.Account?

    @ObservationIgnored private let services: DownloadsServices
    @ObservationIgnored private var readGeneration = 0
    /// While ``observe()`` waits for the item to be found, wakes it when a read finds it.
    @ObservationIgnored private var itemFound: AsyncStream<Signal>.Continuation?
    /// Tests: called after each ``reload()`` that applied its result.
    @ObservationIgnored var reloaded: (@MainActor () -> Void)?

    public init(itemID: UUID, services: DownloadsServices, account: LocalItemDetail.Account? = nil) {
        self.itemID = itemID
        self.services = services
        self.account = account
    }

    /// What to show; `nil` until the item is read, or once it's gone.
    public var detail: LocalItemDetail? {
        item.map { LocalItemDetail(item: $0, account: account) }
    }

    /// The item's downloaded cover file, or `nil` without one.
    public var coverFileURL: URL? {
        item?.coverRelativePath.flatMap(services.localFileURL)
    }

    /// The image in `url`, downsampled so its long side is at most `maxPixelSize`; `nil` if the
    /// file is missing, isn't an image, or fails the shared decoder's source limits
    /// (``ImageThumbnail``).
    @concurrent
    public nonisolated static func coverImage(at url: URL, maxPixelSize: Int) async -> CGImage? {
        try? await ImageThumbnail.decode(contentsOf: url, maxPixelSize: maxPixelSize)
    }

    /// Reads the item, then again after every write to its connection's downloads
    /// (``DownloadsServices/localItemUpdates``), so a deletion in another window updates the rows
    /// and totals or sets ``isDeleted``. Until the item is read (a failed or empty first read),
    /// or without those updates, it reads the item again after each completed download of it,
    /// and moves to the updates once a read (such as a retry) finds the item. Runs until the task
    /// is cancelled.
    public func observe() async {
        // Subscribed before the read, so a completion during it is followed by another read.
        let events = await services.control.events()
        await reload()
        if let updates = await storeUpdates() {
            await follow(updates)
            return
        }
        let (signals, signal) = AsyncStream.makeStream(of: Signal.self)
        let forwarding = Task {
            for await event in events { signal.yield(.event(event)) }
        }
        itemFound = signal
        defer {
            forwarding.cancel()
            itemFound = nil
        }
        for await next in signals {
            switch next {
            case .event(.completed(_, let completedItemID, let key)):
                let sameServerItem =
                    key.serverConnectionID == item?.serverConnectionID && key.libraryItemId == item?.libraryItemId
                if completedItemID == itemID || sameServerItem { await reload() }
            case .event:
                continue
            case .itemFound:
                guard let updates = await storeUpdates() else { continue }
                // Ends the events subscription; the store reports completions too.
                forwarding.cancel()
                itemFound = nil
                await follow(updates)
                return
            }
        }
    }

    /// What the fallback loop in ``observe()`` waits for.
    private enum Signal: Sendable {
        case event(DownloadManagerEvent)
        /// A read found the item, so its connection's store updates can be followed.
        case itemFound
    }

    /// The item's connection's store updates, or `nil` before the item is read or without them.
    private func storeUpdates() async -> AsyncStream<[LocalLibraryItemDTO]>? {
        guard let connectionID = item?.serverConnectionID else { return nil }
        return try? await services.localItemUpdates?(connectionID)
    }

    /// Reads the item after every store write. The stream's first snapshot is the items as they
    /// are, so a write since the last read is still followed by another read.
    private func follow(_ updates: AsyncStream<[LocalLibraryItemDTO]>) async {
        for await _ in updates { await reload() }
    }

    /// Reads the item again.
    public func reload() async {
        readGeneration += 1
        let generation = readGeneration
        let read = services.localItem
        let id = itemID
        let result: Result<LocalLibraryItemDTO?, any Error>
        do {
            result = .success(try await read(id))
        } catch {
            result = .failure(error)
        }
        guard generation == readGeneration else { return }
        switch result {
        case .success(let fresh):
            item = fresh
            loadError = nil
            if fresh == nil, isLoaded { isDeleted = true }
            if fresh != nil { itemFound?.yield(.itemFound) }
        case .failure(let error):
            loadError = error
            Log.downloads.error(
                "Couldn't read the downloaded item: \(Log.redact(String(describing: error)), privacy: .public)")
        }
        isLoaded = true
        reloaded?()
    }

    /// Deletes the item with all its files.
    public func delete() async {
        let id = itemID
        if await perform({ try await $0.deleteLocalItem(id: id) }) { isDeleted = true }
    }

    /// Deletes one downloaded episode; the item goes with its last one.
    public func deleteEpisode(id episodeId: String) async {
        let id = itemID
        guard await perform({ try await $0.deleteEpisode(itemID: id, episodeId: episodeId) }) else { return }
        await reload()
    }

    /// Runs `action`; `false` after a failure, which sets ``notice``. A `false` result (already
    /// gone) isn't a failure.
    private func perform(_ action: @Sendable (any DownloadControlling) async throws -> Bool) async -> Bool {
        isDeleting = true
        defer { isDeleting = false }
        do {
            _ = try await action(services.control)
            return true
        } catch {
            notice = .deleteFailed
            Log.downloads.error(
                "Couldn't delete downloaded media: \(Log.redact(String(describing: error)), privacy: .public)")
            return false
        }
    }
}
