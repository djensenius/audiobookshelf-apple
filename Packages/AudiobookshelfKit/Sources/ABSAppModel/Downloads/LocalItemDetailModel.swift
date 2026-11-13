import ABSCore
import ABSData
import ABSDownloads
import Foundation
import Observation

/// The local item screen's state and actions (#75): reads one downloaded item, shows it as a
/// ``LocalItemDetail`` for the signed-in account, and deletes it or one of its podcast episodes.
///
/// - ``observe()`` reads the item, then again whenever a download of the same server item
///   completes (another episode arriving).
/// - Deleting the item, or its last episode, sets ``isDeleted``; the view then leaves.
/// - A failed delete sets ``notice``; the view shows it and clears it.
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

    /// Reads the item, then again after each completed download of it, until the task is cancelled.
    public func observe() async {
        // Subscribed before the read, so a completion during it is followed by another read.
        let events = await services.control.events()
        await reload()
        for await event in events {
            guard case .completed(_, let completedItemID, let key) = event else { continue }
            let sameServerItem =
                key.serverConnectionID == item?.serverConnectionID && key.libraryItemId == item?.libraryItemId
            if completedItemID == itemID || sameServerItem { await reload() }
        }
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
