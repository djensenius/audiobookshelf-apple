import ABSCore
import Foundation

/// Adding a podcast (legacy `add-podcast.vue`). The server's `PodcastController` answers ``feed(rssFeed:)`` and
/// ``create(_:)`` with 403 unless the user is an admin or root; upload permission alone isn't enough.
public enum PodcastEndpoints {
    /// `GET /api/search/podcast?term=`: podcasts from the iTunes directory. `country` is the iTunes store, usually
    /// the library's `podcastSearchRegion`; the server uses `us` without it. A blank term is a 400.
    public static func searchDirectory(term: String, country: String? = nil) -> Endpoint<[PodcastDirectoryResult]> {
        var query = [URLQueryItem(name: "term", value: term)]
        if let country, !country.isEmpty { query.append(URLQueryItem(name: "country", value: country)) }
        return Endpoint(.get, "/api/search/podcast", query: query)
    }

    /// `POST /api/podcasts/feed` with `{rssFeed}`: the server fetches and parses the feed. An invalid URL is a 400,
    /// and a feed it couldn't fetch or parse a 404.
    public static func feed(rssFeed: String) -> Endpoint<PodcastFeedResponse> {
        Endpoint(.post, "/api/podcasts/feed", body: PodcastFeedRequest(rssFeed: rssFeed))
    }

    /// `POST /api/podcasts`: creates the podcast's folder and item. An existing or unusable path is a 400 with a
    /// plain-text message; an unknown library or folder a 404.
    public static func create(_ request: NewPodcastRequest) -> Endpoint<LibraryItem> {
        Endpoint(.post, "/api/podcasts", body: request)
    }
}

/// The body of ``PodcastEndpoints/feed(rssFeed:)``.
struct PodcastFeedRequest: Encodable, Sendable {
    let rssFeed: String
}

/// The body of ``PodcastEndpoints/create(_:)``, as legacy `NewPodcastForm.vue` sends it. `nil` fields are omitted.
public struct NewPodcastRequest: Encodable, Sendable, Hashable {
    public let libraryID: String
    public let folderID: String
    /// The podcast's folder on the server: the library folder's path joined with the sanitized title.
    public let path: String
    public let media: Media

    public init(libraryID: String, folderID: String, path: String, media: Media) {
        self.libraryID = libraryID
        self.folderID = folderID
        self.path = path
        self.media = media
    }

    enum CodingKeys: String, CodingKey {
        case path, media
        case libraryID = "libraryId"
        case folderID = "folderId"
    }

    public struct Media: Encodable, Sendable, Hashable {
        public let metadata: Metadata
        public let autoDownloadEpisodes: Bool

        public init(metadata: Metadata, autoDownloadEpisodes: Bool) {
            self.metadata = metadata
            self.autoDownloadEpisodes = autoDownloadEpisodes
        }
    }

    /// The server keeps only string values (`itunesId` too) and non-empty genres; anything else is dropped.
    public struct Metadata: Encodable, Sendable, Hashable {
        public let title: String
        public let author: String?
        public let description: String?
        public let releaseDate: String?
        public let genres: [String]
        public let feedURL: String
        public let imageURL: String?
        public let itunesPageURL: String?
        public let itunesID: String?
        public let itunesArtistID: String?
        public let language: String?
        public let explicit: Bool
        /// `episodic` or `serial`.
        public let type: String?

        public init(
            title: String, author: String? = nil, description: String? = nil, releaseDate: String? = nil,
            genres: [String] = [], feedURL: String, imageURL: String? = nil, itunesPageURL: String? = nil,
            itunesID: String? = nil, itunesArtistID: String? = nil, language: String? = nil, explicit: Bool = false,
            type: String? = nil
        ) {
            self.title = title
            self.author = author
            self.description = description
            self.releaseDate = releaseDate
            self.genres = genres
            self.feedURL = feedURL
            self.imageURL = imageURL
            self.itunesPageURL = itunesPageURL
            self.itunesID = itunesID
            self.itunesArtistID = itunesArtistID
            self.language = language
            self.explicit = explicit
            self.type = type
        }

        enum CodingKeys: String, CodingKey {
            case title, author, description, releaseDate, genres, language, explicit, type
            case feedURL = "feedUrl"
            case imageURL = "imageUrl"
            case itunesPageURL = "itunesPageUrl"
            case itunesID = "itunesId"
            case itunesArtistID = "itunesArtistId"
        }
    }
}
