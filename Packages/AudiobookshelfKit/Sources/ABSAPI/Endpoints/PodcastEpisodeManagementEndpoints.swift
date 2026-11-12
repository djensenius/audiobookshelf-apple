import Foundation

/// Server-side episode management for a podcast in the library (legacy
/// `components/tables/podcast/EpisodesTable.vue`, `PodcastEpisodesFeedModal.vue` and the episode
/// page), as the server's `PodcastController` handles it at v2.26.0. The feed lookup and the
/// download stay on origin: their bodies hold feed and episode URLs.
public enum PodcastEpisodeManagementEndpoints {
    /// `POST /api/podcasts/feed` with `{"rssFeed": url}`: the feed's episodes, for choosing new
    /// ones. Admin and root only (403 otherwise); 400 for an invalid URL and 404 when the feed
    /// can't be read.
    public static func feedEpisodes(rssFeed: String) -> Endpoint<RSSFeedEpisodesResponse> {
        Endpoint(.post, "/api/podcasts/feed", body: FeedRequest(rssFeed: rssFeed), staysOnOrigin: true)
    }

    /// `POST /api/podcasts/:id/download-episodes` with the chosen feed episodes, as the feed lookup
    /// returned them: queues their download on the server. Admin and root with the update
    /// permission only (403 otherwise); 400 for an empty list.
    public static func downloadEpisodes(podcastID: String, episodes: [RSSFeedEpisode]) -> Endpoint<EmptyResponse> {
        Endpoint(
            .post, "/api/podcasts/\(pathSegment(podcastID))/download-episodes", body: episodes, staysOnOrigin: true)
    }

    /// `GET /api/podcasts/:id/clear-queue`: drops the podcast's queued episode downloads. Admin and
    /// root only (403 otherwise).
    public static func clearDownloadQueue(podcastID: String) -> Endpoint<EmptyResponse> {
        Endpoint(.get, "/api/podcasts/\(pathSegment(podcastID))/clear-queue")
    }

    /// `DELETE /api/podcasts/:id/episode/:episodeId`: removes the episode from the library and,
    /// with `deleteFile` (`?hard=1`), its audio file too. Needs the delete permission (403
    /// otherwise); 404 when the episode is gone. The updated item the server answers with is
    /// ignored.
    public static func removeEpisode(podcastID: String, episodeID: String, deleteFile: Bool) -> Endpoint<EmptyResponse>
    {
        Endpoint(
            .delete, "/api/podcasts/\(pathSegment(podcastID))/episode/\(pathSegment(episodeID))",
            query: deleteFile ? [URLQueryItem(name: "hard", value: "1")] : [])
    }

    struct FeedRequest: Encodable, Sendable {
        let rssFeed: String
    }
}
