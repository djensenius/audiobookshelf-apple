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
    public init(item: LibraryItem, progress: [UserFinishedMediaResponse.Entry]) {
        let podcast = item.podcast
        isSerial = podcast?.metadata.type == "serial"
        episodes = podcast?.episodes ?? []
        finishedEpisodeIDs = Set(
            progress.filter { $0.libraryItemId == item.id && $0.isFinished }.compactMap(\.episodeId))
    }

    /// The episodes in the legacy "next episode" order (`pages/item/_id/index.vue` `play()`): by
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

    /// The first unfinished episode in ``playOrder`` other than `episodeID` (the one that is
    /// ending, whose finish may not be synced yet), or `nil` when every other episode is finished.
    /// Unlike the legacy play button, there is no fallback to the first episode.
    public func nextUnfinished(after episodeID: String) -> PodcastEpisode? {
        playOrder.first { $0.id != episodeID && !finishedEpisodeIDs.contains($0.id) }
    }
}

/// Loads a podcast's ``PodcastEpisodeListing``; ``APIPodcastEpisodeSource`` is the live one.
public protocol PodcastEpisodeSource: Sendable {
    func listing(podcastItemID: String) async throws -> PodcastEpisodeListing
}

/// ``PodcastEpisodeSource`` over one connection's ``APIClient``: the expanded item and the
/// user's finished flags from `GET /api/me`. An episode's finished change that hasn't synced yet
/// (`finishedDirty` in local progress) overrides the server's. Local progress is read in
/// ``PodcastEpisodeListing/playOrder`` only until two episodes are unfinished, so
/// `finishedEpisodeIDs` is exact for that prefix, which is all
/// ``PodcastEpisodeListing/nextUnfinished(after:)`` reads, whichever episode is ending.
public struct APIPodcastEpisodeSource: PodcastEpisodeSource {
    private let serverConnectionID: UUID
    private let localProgress: (any LocalProgressReading)?
    private let fetchItem: @Sendable (String) async throws -> LibraryItem
    private let fetchFinished: @Sendable () async throws -> UserFinishedMediaResponse

    public init(client: APIClient, serverConnectionID: UUID, localProgress: (any LocalProgressReading)?) {
        self.init(
            serverConnectionID: serverConnectionID, localProgress: localProgress,
            fetchItem: { try await client.send(ItemEndpoints.item(id: $0)) },
            fetchFinished: { try await client.send(UserEndpoints.me()) })
    }

    init(
        serverConnectionID: UUID, localProgress: (any LocalProgressReading)?,
        fetchItem: @escaping @Sendable (String) async throws -> LibraryItem,
        fetchFinished: @escaping @Sendable () async throws -> UserFinishedMediaResponse
    ) {
        self.serverConnectionID = serverConnectionID
        self.localProgress = localProgress
        self.fetchItem = fetchItem
        self.fetchFinished = fetchFinished
    }

    public func listing(podcastItemID: String) async throws -> PodcastEpisodeListing {
        async let item = fetchItem(podcastItemID)
        async let finished = fetchFinished()
        var listing = PodcastEpisodeListing(item: try await item, progress: try await finished.mediaProgress)
        guard let localProgress else { return listing }
        var unfinished = 0
        for episode in listing.playOrder where unfinished < 2 {
            let key = MediaKey(
                serverConnectionID: serverConnectionID, libraryItemId: podcastItemID, episodeId: episode.id)
            if let local = try? await localProgress.progress(for: key), local.finishedDirty {
                if local.isFinished {
                    listing.finishedEpisodeIDs.insert(episode.id)
                } else {
                    listing.finishedEpisodeIDs.remove(episode.id)
                }
            }
            if !listing.finishedEpisodeIDs.contains(episode.id) { unfinished += 1 }
        }
        return listing
    }
}
