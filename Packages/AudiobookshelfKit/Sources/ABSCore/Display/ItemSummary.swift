import Foundation

/// What an ``ItemSummary`` stands for.
public enum ItemKind: Sendable, Hashable {
    case book
    /// A podcast as a whole. Playing happens per episode.
    case podcast
    case episode
    /// A series collapsed into one entry of a library list.
    case series
}

/// The inputs of a cover request. The connection's UUID comes from the environment, so the
/// item can't build an ``ImageKey`` itself.
public struct CoverRef: Sendable, Hashable {
    /// The library item whose cover this is.
    public let entityID: String
    public let updatedAt: Int?
    /// Set when the item's `coverPath` is an absolute `http(s)` URL.
    public let externalURL: URL?

    public init(entityID: String, updatedAt: Int? = nil, externalURL: URL? = nil) {
        self.entityID = entityID
        self.updatedAt = updatedAt
        self.externalURL = externalURL
    }

    /// `nil` when the item has no `coverPath`.
    public init?(item: LibraryItem) {
        guard let path = item.media?.coverPath, !path.isEmpty else { return nil }
        var external: URL?
        if let url = URL(string: path), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            external = url
        }
        self.init(entityID: item.id, updatedAt: item.updatedAt, externalURL: external)
    }

    public func key(serverID: UUID, bucket: ImageWidthBucket = .medium) -> ImageKey {
        ImageKey(
            serverID: serverID, kind: .itemCover, entityID: entityID, updatedAt: updatedAt, bucket: bucket,
            externalURL: externalURL)
    }
}

/// The slim value one cell needs. A list holds one per loaded item, so it keeps only what a
/// card, row or action menu shows; never the 25-field ``LibraryItem``.
///
/// Every source maps through ``init(item:episode:)``: server lists and shelves, and later
/// downloaded items rebuilt as a ``LibraryItem``.
public struct ItemSummary: Sendable, Hashable, Identifiable {
    /// The item ID; `"<item>-<episode>"` for an episode; `"series-<id>"` for a collapsed series.
    public let id: String
    /// The library item to open or play. For a collapsed series, its first item.
    public let itemID: String
    public let episodeID: String?
    public let seriesID: String?
    public let kind: ItemKind
    public let title: String
    /// The author for a book, the podcast's author for a podcast, the podcast's title for an episode.
    public let subtitle: String?
    /// Series name and sequence, for example `The Stormlight Archive #2`.
    public let seriesText: String?
    /// Seconds.
    public let duration: TimeInterval?
    /// The number of books in a collapsed series.
    public let bookCount: Int?
    public let cover: CoverRef?
    public let isExplicit: Bool
    public let isAbridged: Bool
    /// Missing or invalid on the server: it can't be played.
    public let isMissing: Bool
    public let hasAudio: Bool

    public init(
        id: String, itemID: String, episodeID: String? = nil, seriesID: String? = nil, kind: ItemKind, title: String,
        subtitle: String? = nil, seriesText: String? = nil, duration: TimeInterval? = nil, bookCount: Int? = nil,
        cover: CoverRef? = nil, isExplicit: Bool = false, isAbridged: Bool = false, isMissing: Bool = false,
        hasAudio: Bool = true
    ) {
        self.id = id
        self.itemID = itemID
        self.episodeID = episodeID
        self.seriesID = seriesID
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.seriesText = seriesText
        self.duration = duration
        self.bookCount = bookCount
        self.cover = cover
        self.isExplicit = isExplicit
        self.isAbridged = isAbridged
        self.isMissing = isMissing
        self.hasAudio = hasAudio
    }

    /// Maps a book, podcast, podcast episode or collapsed series.
    ///
    /// A podcast item becomes an episode when `episode` is given or the item carries a
    /// `recentEpisode` (episode shelves); it then shows the episode's title and duration and the
    /// podcast's title, cover and explicit flag.
    public init(item: LibraryItem, episode: PodcastEpisode? = nil) {
        let unplayable = item.isMissing || item.isInvalid
        let cover = CoverRef(item: item)
        if let collapsed = item.collapsedSeries {
            self.init(
                id: "series-\(collapsed.id)", itemID: item.id, seriesID: collapsed.id, kind: .series,
                title: collapsed.name, bookCount: collapsed.numBooks ?? collapsed.libraryItemIds?.count, cover: cover,
                isMissing: unplayable, hasAudio: false)
            return
        }
        switch item.media {
        case .book(let book):
            let metadata = book.metadata
            self.init(
                id: item.id, itemID: item.id, kind: .book, title: metadata.title,
                subtitle: Self.nonEmpty(metadata.authorName)
                    ?? Self.nonEmpty(metadata.authors?.map(\.name).joined(separator: ", ")),
                seriesText: Self.seriesText(item: item, metadata: metadata),
                duration: Self.positive(book.duration), cover: cover, isExplicit: metadata.explicit ?? false,
                isAbridged: metadata.abridged ?? false, isMissing: unplayable, hasAudio: Self.hasAudio(book))
        case .podcast(let podcast):
            let metadata = podcast.metadata
            if let episode = episode ?? item.recentEpisode {
                self.init(
                    id: "\(item.id)-\(episode.id)", itemID: item.id, episodeID: episode.id, kind: .episode,
                    title: episode.title, subtitle: metadata.title, duration: Self.positive(episode.duration),
                    cover: cover, isExplicit: metadata.explicit ?? false, isMissing: unplayable)
            } else {
                self.init(
                    id: item.id, itemID: item.id, kind: .podcast, title: metadata.title,
                    subtitle: Self.nonEmpty(metadata.author), cover: cover, isExplicit: metadata.explicit ?? false,
                    isMissing: unplayable, hasAudio: false)
            }
        case nil:
            // A media type this client doesn't know: show what identifies it.
            self.init(
                id: item.id, itemID: item.id, kind: .book, title: item.relPath ?? item.id, isMissing: unplayable,
                hasAudio: false)
        }
    }

    /// The cover request for `serverID`, or `nil` when the item has no cover.
    public func coverKey(serverID: UUID, bucket: ImageWidthBucket = .medium) -> ImageKey? {
        cover?.key(serverID: serverID, bucket: bucket)
    }

    /// The key progress is stored under (``MediaProgress/key(libraryItemID:episodeID:)``).
    public var progressKey: String {
        MediaProgress.key(libraryItemID: itemID, episodeID: episodeID)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func positive(_ seconds: Double?) -> TimeInterval? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    /// Series from the list context (`series`, with this item's sequence), else the book's own
    /// first series, else the server's flattened `seriesName` (which already ends in `#<sequence>`).
    private static func seriesText(item: LibraryItem, metadata: BookMetadata) -> String? {
        if let series = item.series ?? metadata.series?.first {
            guard let sequence = nonEmpty(series.sequence) else { return series.name }
            return "\(series.name) #\(sequence)"
        }
        return nonEmpty(metadata.seriesName)
    }

    /// Minified items carry counts; expanded ones carry files. With neither, a duration decides,
    /// and an item that says nothing is assumed playable.
    private static func hasAudio(_ book: Book) -> Bool {
        if let count = book.numTracks ?? book.numAudioFiles ?? book.audioFiles?.count ?? book.tracks?.count {
            return count > 0
        }
        return book.duration.map { $0 > 0 } ?? true
    }
}

/// A series as shown on a series card.
public struct SeriesSummary: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let bookCount: Int
    /// Seconds.
    public let totalDuration: TimeInterval?
    /// The covers of the first books, at most ``maxCovers``.
    public let covers: [CoverRef]

    public static let maxCovers = 4

    public init(id: String, name: String, bookCount: Int, totalDuration: TimeInterval? = nil, covers: [CoverRef] = []) {
        self.id = id
        self.name = name
        self.bookCount = bookCount
        self.totalDuration = totalDuration
        self.covers = Array(covers.prefix(Self.maxCovers))
    }

    public init(series: Series) {
        let books = series.books ?? []
        self.init(
            id: series.id, name: series.name, bookCount: books.count,
            totalDuration: series.totalDuration.flatMap { $0 > 0 ? $0 : nil },
            covers: books.compactMap { CoverRef(item: $0) })
    }
}

/// An author as shown on an author card.
public struct AuthorSummary: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let bookCount: Int?
    public let hasImage: Bool
    public let imageUpdatedAt: Int?

    public init(id: String, name: String, bookCount: Int? = nil, hasImage: Bool = false, imageUpdatedAt: Int? = nil) {
        self.id = id
        self.name = name
        self.bookCount = bookCount
        self.hasImage = hasImage
        self.imageUpdatedAt = imageUpdatedAt
    }

    public init(author: Author) {
        self.init(
            id: author.id, name: author.name, bookCount: author.numBooks, hasImage: author.imagePath != nil,
            imageUpdatedAt: author.updatedAt)
    }

    /// `nil` when the author has no image.
    public func imageKey(serverID: UUID, bucket: ImageWidthBucket = .medium) -> ImageKey? {
        guard hasImage else { return nil }
        return ImageKey(
            serverID: serverID, kind: .authorImage, entityID: id, updatedAt: imageUpdatedAt, bucket: bucket)
    }
}
