import ABSAPI
import ABSCore
import ABSData
import Foundation

/// A podcast's episodes and which of them the user finished, for picking the next episode.
public struct PodcastEpisodeListing: Sendable, Hashable {
    /// `serial` podcasts play oldest first; episodic ones newest first.
    public var isSerial: Bool
    /// In the server's order.
    public var episodes: [PodcastEpisode]
    public var finishedEpisodeIDs: Set<String>

    public init(isSerial: Bool, episodes: [PodcastEpisode], finishedEpisodeIDs: Set<String>) {
        self.isSerial = isSerial
        self.episodes = episodes
        self.finishedEpisodeIDs = finishedEpisodeIDs
    }

    /// The podcast `item`'s episodes, finished per the user's `progress`.
    public init(item: LibraryItem, progress: [MediaProgress]) {
        let podcast = item.podcast
        isSerial = podcast?.metadata.type == "serial"
        episodes = podcast?.episodes ?? []
        finishedEpisodeIDs = Set(
            progress.filter { $0.libraryItemId == item.id && $0.isFinished }.compactMap(\.episodeId))
    }

    /// The episodes in the legacy "next episode" order (`pages/item/_id/index.vue`): by
    /// `publishedAt`, oldest first for serial podcasts and newest first otherwise. An episode
    /// without a date counts as later than any dated one (the legacy string compare), and ties
    /// keep the server's order.
    public var playOrder: [PodcastEpisode] {
        episodes.enumerated().sorted { lhs, rhs in
            let left = lhs.element.publishedAt ?? .max
            let right = rhs.element.publishedAt ?? .max
            guard left != right else { return lhs.offset < rhs.offset }
            return isSerial ? left < right : left > right
        }.map(\.element)
    }

    /// The first unfinished episode in ``playOrder`` other than `episodeID` (the one that just
    /// ended, whose finish may not be synced yet), or `nil` when every other episode is finished.
    public func nextUnfinished(after episodeID: String) -> PodcastEpisode? {
        playOrder.first { $0.id != episodeID && !finishedEpisodeIDs.contains($0.id) }
    }
}

/// Loads a podcast's ``PodcastEpisodeListing``; ``APIPodcastEpisodeSource`` is the live one.
public protocol PodcastEpisodeSource: Sendable {
    func listing(podcastItemID: String) async throws -> PodcastEpisodeListing
}

/// ``PodcastEpisodeSource`` over one connection's ``APIClient``: the expanded item and the user's
/// progress from `GET /api/me`. An episode's finished change that hasn't synced yet
/// (`finishedDirty` in local progress) overrides the server's.
public struct APIPodcastEpisodeSource: PodcastEpisodeSource {
    private let client: APIClient
    private let serverConnectionID: UUID
    private let localProgress: (any LocalProgressReading)?

    public init(client: APIClient, serverConnectionID: UUID, localProgress: (any LocalProgressReading)?) {
        self.client = client
        self.serverConnectionID = serverConnectionID
        self.localProgress = localProgress
    }

    public func listing(podcastItemID: String) async throws -> PodcastEpisodeListing {
        async let item = client.send(ItemEndpoints.item(id: podcastItemID))
        async let user = client.send(UserEndpoints.me)
        var listing = PodcastEpisodeListing(item: try await item, progress: try await user.mediaProgress)
        guard let localProgress else { return listing }
        for episode in listing.episodes {
            let key = MediaKey(
                serverConnectionID: serverConnectionID, libraryItemId: podcastItemID, episodeId: episode.id)
            guard let local = try? await localProgress.progress(for: key), local.finishedDirty else { continue }
            if local.isFinished {
                listing.finishedEpisodeIDs.insert(episode.id)
            } else {
                listing.finishedEpisodeIDs.remove(episode.id)
            }
        }
        return listing
    }
}
