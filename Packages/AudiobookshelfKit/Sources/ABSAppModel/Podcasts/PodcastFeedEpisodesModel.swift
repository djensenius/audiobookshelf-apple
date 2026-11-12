import ABSAPI
import ABSCore
import Foundation
import Observation

/// The feed episodes sheet of a podcast in the library (legacy `PodcastEpisodesFeedModal.vue`):
/// loads the podcast's RSS feed through the server, newest first, marks the episodes the library
/// already has, and queues the chosen ones for download on the server.
///
/// - An episode is in the library when an episode of the podcast has the same enclosure URL
///   (trimmed), as legacy matched them; those can't be selected.
/// - Episodes without a publish date sort last, in the feed's order.
/// - One load or download runs at a time; a download sends the episodes exactly as the feed
///   lookup returned them, and is refused when the request would exceed ``maxRequestBytes``.
@MainActor
@Observable
public final class PodcastFeedEpisodesModel {
    public enum Phase: Sendable, Hashable {
        case idle
        case loading
        case loaded
        case failed
    }

    /// One feed episode as the sheet lists it.
    public struct Row: Sendable, Hashable, Identifiable {
        /// The episode's place in the sorted feed.
        public let id: Int
        public let episode: RSSFeedEpisode
        /// The library already has an episode with this enclosure URL.
        public let isInLibrary: Bool
    }

    /// What a download ended with.
    public enum DownloadOutcome: Sendable, Hashable {
        /// The server queued `count` episodes.
        case queued(count: Int)
        /// The request was larger than ``maxRequestBytes``; nothing was sent.
        case tooLarge
        case failed
        /// Nothing was selected, or a load or download was running; nothing was sent.
        case ignored
    }

    /// Legacy refused requests over 5 MB, under the server's body limit.
    public static let maxRequestBytes = 5 * 1024 * 1024

    public let podcastID: String
    public let feedURL: String
    public private(set) var phase = Phase.idle
    public private(set) var rows: [Row] = []
    /// The selected rows' IDs; never an episode already in the library.
    public private(set) var selection: Set<Int> = []
    public private(set) var isDownloading = false

    @ObservationIgnored private var libraryURLs: Set<String>
    @ObservationIgnored private let service: any PodcastEpisodeManagementService

    /// - Parameters:
    ///   - libraryEpisodes: The podcast's episodes, which are marked in the feed.
    public init(
        podcastID: String, feedURL: String, libraryEpisodes: [PodcastEpisode],
        service: any PodcastEpisodeManagementService
    ) {
        self.podcastID = podcastID
        self.feedURL = feedURL
        self.service = service
        libraryURLs = Self.libraryURLs(libraryEpisodes)
    }

    /// Marks the feed against the podcast's episodes as they are now (after a reload, once the
    /// server has downloaded queued episodes), dropping newly marked rows from the selection.
    public func updateLibraryEpisodes(_ libraryEpisodes: [PodcastEpisode]) {
        libraryURLs = Self.libraryURLs(libraryEpisodes)
        rows = rows.map {
            Row(id: $0.id, episode: $0.episode, isInLibrary: libraryURLs.contains($0.episode.enclosureURL))
        }
        selection.formIntersection(selectableIDs)
    }

    /// The rows that can be selected.
    public var selectableIDs: Set<Int> { Set(rows.filter { !$0.isInLibrary }.map(\.id)) }

    /// Every selectable row is selected, and there is at least one.
    public var isAllSelected: Bool {
        let selectable = selectableIDs
        return !selectable.isEmpty && selection == selectable
    }

    public var canDownload: Bool { !selection.isEmpty && !isDownloading && phase == .loaded }

    /// Loads the feed, replacing the rows and clearing the selection; ignored while loading or
    /// downloading.
    public func load() async {
        guard phase != .loading, !isDownloading else { return }
        phase = .loading
        do {
            let episodes = try await service.feedEpisodes(rssFeed: feedURL)
            rows = Self.sorted(episodes).enumerated().map { index, episode in
                Row(id: index, episode: episode, isInLibrary: libraryURLs.contains(episode.enclosureURL))
            }
            selection = []
            phase = .loaded
        } catch {
            phase = .failed
        }
    }

    /// Selects or deselects the row `id`; rows in the library and unknown IDs are ignored.
    public func toggle(_ id: Int) {
        guard !isDownloading, selectableIDs.contains(id) else { return }
        if selection.remove(id) == nil { selection.insert(id) }
    }

    /// Selects every selectable row, or clears the selection when they all are.
    public func toggleAll() {
        guard !isDownloading else { return }
        selection = isAllSelected ? [] : selectableIDs
    }

    /// Queues the selected episodes for download on the server. The selection is cleared when
    /// the server accepts them or refuses them, as legacy did, and kept when the request is too
    /// large, so it can be trimmed.
    public func download() async -> DownloadOutcome {
        guard canDownload else { return .ignored }
        let episodes = rows.filter { selection.contains($0.id) }.map(\.episode)
        guard let size = try? JSONEncoder().encode(episodes).count, size <= Self.maxRequestBytes else {
            return .tooLarge
        }
        isDownloading = true
        defer { isDownloading = false }
        do {
            try await service.downloadEpisodes(podcastID: podcastID, episodes: episodes)
            selection = []
            return .queued(count: episodes.count)
        } catch {
            selection = []
            return .failed
        }
    }

    /// Newest first; undated episodes last, in the feed's order.
    static func sorted(_ episodes: [RSSFeedEpisode]) -> [RSSFeedEpisode] {
        episodes.enumerated().sorted { lhs, rhs in
            switch (lhs.element.publishedAt, rhs.element.publishedAt) {
            case (let left?, let right?) where left != right: left > right
            case (nil, _?): false
            case (_?, nil): true
            default: lhs.offset < rhs.offset
            }
        }
        .map(\.element)
    }

    private static func libraryURLs(_ episodes: [PodcastEpisode]) -> Set<String> {
        Set(episodes.compactMap { normalized($0.enclosure?.url) })
    }

    private static func normalized(_ url: String?) -> String? {
        guard let url = url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { return nil }
        return url
    }
}
