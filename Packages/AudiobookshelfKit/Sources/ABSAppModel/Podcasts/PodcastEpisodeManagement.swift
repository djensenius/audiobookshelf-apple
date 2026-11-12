import ABSAPI
import ABSCore
import Foundation
import Observation

/// Server-side episode management for a podcast in the library; `APIClient` conforms.
public protocol PodcastEpisodeManagementService: Sendable {
    /// The episodes of the feed at `rssFeed`, as the server parsed it.
    func feedEpisodes(rssFeed: String) async throws -> [RSSFeedEpisode]
    /// Queues `episodes`, as ``feedEpisodes(rssFeed:)`` returned them, for download on the server.
    func downloadEpisodes(podcastID: String, episodes: [RSSFeedEpisode]) async throws
    /// Drops the podcast's queued episode downloads.
    func clearDownloadQueue(podcastID: String) async throws
    /// Removes an episode from the library and, with `deleteFile`, its audio file.
    func removeEpisode(podcastID: String, episodeID: String, deleteFile: Bool) async throws
}

extension APIClient: PodcastEpisodeManagementService {
    public func feedEpisodes(rssFeed: String) async throws -> [RSSFeedEpisode] {
        try await send(PodcastEpisodeManagementEndpoints.feedEpisodes(rssFeed: rssFeed)).episodes
    }

    public func downloadEpisodes(podcastID: String, episodes: [RSSFeedEpisode]) async throws {
        _ = try await send(PodcastEpisodeManagementEndpoints.downloadEpisodes(podcastID: podcastID, episodes: episodes))
    }

    public func clearDownloadQueue(podcastID: String) async throws {
        _ = try await send(PodcastEpisodeManagementEndpoints.clearDownloadQueue(podcastID: podcastID))
    }

    public func removeEpisode(podcastID: String, episodeID: String, deleteFile: Bool) async throws {
        _ = try await send(
            PodcastEpisodeManagementEndpoints.removeEpisode(
                podcastID: podcastID, episodeID: episodeID, deleteFile: deleteFile))
    }
}

/// Which episode management actions the signed-in user is offered for a podcast, as the server's
/// `PodcastController` allows them at v2.26.0 and legacy `EpisodesTable.vue` and the episode page
/// show them (admin or root only):
/// - Finding feed episodes and downloading them needs an admin or root with the update
///   permission (the feed lookup is admin-only; the download is a POST, which needs `canUpdate`),
///   and a feed URL.
/// - Clearing the download queue needs an admin or root.
/// - Removing an episode needs an admin or root (legacy) with the delete permission (server
///   `canDelete`).
///
/// Nothing is offered to an inactive user, without a signed-in user (offline), or once the
/// podcast is gone from the server.
public struct PodcastEpisodeManagementAccess: Sendable, Hashable {
    public var canFindEpisodes: Bool
    public var canClearDownloadQueue: Bool
    public var canRemoveEpisodes: Bool

    public static let none = PodcastEpisodeManagementAccess(
        canFindEpisodes: false, canClearDownloadQueue: false, canRemoveEpisodes: false)

    public init(canFindEpisodes: Bool, canClearDownloadQueue: Bool, canRemoveEpisodes: Bool) {
        self.canFindEpisodes = canFindEpisodes
        self.canClearDownloadQueue = canClearDownloadQueue
        self.canRemoveEpisodes = canRemoveEpisodes
    }

    public init(user: User?, podcast: Podcast?, isGone: Bool) {
        guard let user, let podcast, user.isActive, !isGone, user.type == .admin || user.type == .root else {
            self = .none
            return
        }
        self.init(
            canFindEpisodes: user.permissions.update && Self.feedURL(of: podcast) != nil,
            canClearDownloadQueue: true,
            canRemoveEpisodes: user.permissions.delete)
    }

    /// Anything to show in the podcast's management menu.
    public var offersAny: Bool { canFindEpisodes || canClearDownloadQueue || canRemoveEpisodes }

    /// The podcast's feed URL, trimmed; `nil` when blank.
    public static func feedURL(of podcast: Podcast) -> String? {
        guard let url = podcast.metadata.feedUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty
        else { return nil }
        return url
    }
}

/// Clears a podcast's download queue, removes its episodes from the server and opens its feed
/// episodes (``feed``), as ``access`` allows them now. Clearing and removing run one at a time
/// (``isBusy``); the caller reloads the item after a removal.
///
/// The feed is made with the current service, and closed when the service is replaced (a
/// reconnect) or Find Episodes is no longer allowed, so a stale sheet can't download.
@MainActor
@Observable
public final class PodcastEpisodeActionsModel {
    public let podcastID: String
    /// An action is in flight; the actions are disabled meanwhile.
    public private(set) var isBusy = false
    /// What the signed-in user may do now; losing Find Episodes closes the feed.
    public var access: PodcastEpisodeManagementAccess {
        didSet {
            if !access.canFindEpisodes { feed = nil }
        }
    }
    /// The open feed episodes sheet's model; `nil` when it's closed.
    public private(set) var feed: PodcastFeedEpisodesModel?

    @ObservationIgnored private var service: any PodcastEpisodeManagementService

    public init(
        podcastID: String, access: PodcastEpisodeManagementAccess, service: any PodcastEpisodeManagementService
    ) {
        self.podcastID = podcastID
        self.access = access
        self.service = service
    }

    /// Clearing the queue is allowed and nothing is running.
    public var canClearDownloadQueue: Bool { access.canClearDownloadQueue && !isBusy }
    /// Removing an episode is allowed and nothing is running.
    public var canRemoveEpisodes: Bool { access.canRemoveEpisodes && !isBusy }

    /// Uses `service` (the account's new client) for later actions, and closes the feed made
    /// with the old one.
    public func replaceService(_ service: any PodcastEpisodeManagementService) {
        self.service = service
        feed = nil
    }

    /// Opens `podcast`'s feed episodes, marking `libraryEpisodes`; `nil` (and nothing opened)
    /// when Find Episodes isn't allowed or the podcast has no feed URL.
    @discardableResult
    public func openFeed(podcast: Podcast, libraryEpisodes: [PodcastEpisode]) -> PodcastFeedEpisodesModel? {
        guard access.canFindEpisodes, let feedURL = PodcastEpisodeManagementAccess.feedURL(of: podcast) else {
            return nil
        }
        let feed = PodcastFeedEpisodesModel(
            podcastID: podcastID, feedURL: feedURL, libraryEpisodes: libraryEpisodes, service: service)
        self.feed = feed
        return feed
    }

    public func closeFeed() {
        feed = nil
    }

    /// Clears the download queue; `nil` if it isn't allowed now or another action was running,
    /// else whether it worked.
    public func clearDownloadQueue() async -> Bool? {
        guard access.canClearDownloadQueue else { return nil }
        return await run { [podcastID] service in try await service.clearDownloadQueue(podcastID: podcastID) }
    }

    /// Removes `episodeID` and, with `deleteFile`, its audio file; `nil` if it isn't allowed now
    /// or another action was running, else whether it worked.
    public func removeEpisode(_ episodeID: String, deleteFile: Bool) async -> Bool? {
        guard access.canRemoveEpisodes else { return nil }
        return await run { [podcastID] service in
            try await service.removeEpisode(podcastID: podcastID, episodeID: episodeID, deleteFile: deleteFile)
        }
    }

    private func run(_ action: (any PodcastEpisodeManagementService) async throws -> Void) async -> Bool? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            try await action(service)
            return true
        } catch {
            return false
        }
    }
}
