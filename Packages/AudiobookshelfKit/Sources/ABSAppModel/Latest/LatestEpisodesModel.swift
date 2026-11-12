import ABSAPI
import ABSCore
import Foundation

/// The endpoint the Latest screen of a podcast library uses. `APIClient` conforms; tests use fakes.
public protocol LatestEpisodesService: Sendable {
    /// `GET /api/libraries/:id/recent-episodes`: one page of the library's episodes, newest first.
    func recentEpisodes(libraryID: String, page: Int, limit: Int) async throws -> RecentEpisodesPage
}

extension APIClient: LatestEpisodesService {
    public func recentEpisodes(libraryID: String, page: Int, limit: Int) async throws -> RecentEpisodesPage {
        try await send(LibraryEndpoints.recentEpisodes(libraryID: libraryID, page: page, limit: limit))
    }
}

/// One row of the Latest screen: the episode, and the ``ItemSummary`` its play and finished
/// actions take, with the podcast's title, cover and explicit flag.
public struct LatestEpisode: Sendable, Hashable, Identifiable {
    public let episode: PodcastEpisode
    public let summary: ItemSummary

    /// `"<item>-<episode>"`, as ``ItemSummary`` identifies episodes.
    public var id: String { summary.id }
    /// The podcast's library item, which episode routes and progress use.
    public var itemID: String { summary.itemID }

    /// `nil` when the server didn't say which library item the episode belongs to: it can't be
    /// opened, played or matched with progress.
    public init?(_ recent: RecentEpisode) {
        let episode = recent.episode
        guard let itemID = Self.nonEmpty(episode.libraryItemId) ?? Self.nonEmpty(recent.podcast?.libraryItemId) else {
            return nil
        }
        let metadata = recent.podcast?.metadata
        var cover: CoverRef?
        if let path = Self.nonEmpty(recent.podcast?.coverPath) {
            let url = URL(string: path)
            let scheme = url?.scheme?.lowercased()
            cover = CoverRef(entityID: itemID, externalURL: scheme == "http" || scheme == "https" ? url : nil)
        }
        let duration = episode.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.episode = episode
        summary = ItemSummary(
            id: "\(itemID)-\(episode.id)", itemID: itemID, episodeID: episode.id, kind: .episode,
            title: episode.title, subtitle: Self.nonEmpty(metadata?.title), duration: duration, cover: cover,
            isExplicit: metadata?.explicit ?? false)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

/// The Latest section of a podcast library (legacy `pages/bookshelf/latest.vue`): its episodes,
/// newest first, a page at a time, each with the user's progress and the play button's status.
///
/// Legacy loads one page of 50; this pages on with the same size as the user scrolls. The
/// server sends no total, so a short page ends the list. Paging, in-flight deduplication and
/// dropping late pages after ``ItemListModel/setQuery(_:)`` (another library) or a refresh are
/// ``list``'s; a page answered after an account switch is dropped by the service
/// (`LibraryStoreServices` throws `CancellationError`), and views build a new model per account
/// and library.
///
/// Not `@Observable`: it stores nothing that changes. Views observe ``list`` and the progress
/// cache's entries.
@MainActor
public final class LatestEpisodesModel {
    /// Legacy's page size.
    public static let defaultPageSize = 50

    /// The episodes; its query is the library ID.
    public let list: ItemListModel<String, LatestEpisode>
    private let cache: ProgressCache

    public init(
        service: any LatestEpisodesService, libraryID: String, cache: ProgressCache,
        pageSize: Int = LatestEpisodesModel.defaultPageSize, prefetchThreshold: Int = 10,
        connectionKey: LibraryConnectionKey? = nil
    ) {
        self.cache = cache
        list = ItemListModel(
            query: libraryID, pageSize: pageSize, prefetchThreshold: prefetchThreshold, connectionKey: connectionKey
        ) { libraryID, page, limit in
            let response = try await service.recentEpisodes(libraryID: libraryID, page: page, limit: limit)
            // Paging counts the server's rows, including episodes dropped here.
            return PagedResults(
                results: response.episodes.compactMap(LatestEpisode.init), total: nil, limit: response.limit,
                page: response.page, rawCount: response.rawCount)
        }
    }

    /// The user's progress on `row`'s episode, read from the cache so the row follows it.
    public func progress(for row: LatestEpisode) -> MediaProgress? {
        cache.progress(libraryItemID: row.itemID, episodeID: row.episode.id)
    }

    /// ``progress(for:)`` as rows show it.
    public func itemProgress(for row: LatestEpisode) -> ItemProgress? {
        progress(for: row).map(ItemProgress.init)
    }

    /// The play button's status, as on the podcast screen.
    public func status(for row: LatestEpisode) -> PodcastDetailModel.EpisodeStatus {
        PodcastDetailModel.status(for: row.episode, progress: progress(for: row))
    }
}
