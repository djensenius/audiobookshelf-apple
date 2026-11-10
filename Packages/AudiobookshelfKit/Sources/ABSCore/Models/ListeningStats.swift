import Foundation

/// `GET /api/me/listening-stats` (server `ApiRouter.getUserListeningStatsHelpers`). Times are
/// seconds.
public struct ListeningStats: Sendable, Hashable, Codable {
    public var totalTime: Double
    /// Keyed by library item ID. Sessions without one are grouped under the key `"null"`.
    public var items: [String: ListeningStatsItem]
    /// Keyed by `YYYY-MM-DD` in the server's time zone.
    public var days: [String: Double]
    /// Keyed by English weekday name, for example `Monday`.
    public var dayOfWeek: [String: Double]
    public var today: Double
    /// The ten most recently updated sessions. Malformed sessions are skipped; old rows can
    /// have `libraryItemId: null` or a string `timeListening`.
    public var recentSessions: [PlaybackSession]

    public init(
        totalTime: Double = 0, items: [String: ListeningStatsItem] = [:], days: [String: Double] = [:],
        dayOfWeek: [String: Double] = [:], today: Double = 0, recentSessions: [PlaybackSession] = []
    ) {
        self.totalTime = totalTime
        self.items = items
        self.days = days
        self.dayOfWeek = dayOfWeek
        self.today = today
        self.recentSessions = recentSessions
    }

    enum CodingKeys: String, CodingKey {
        case totalTime, items, days, dayOfWeek, today, recentSessions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalTime = try container.decodeIfPresent(Double.self, forKey: .totalTime) ?? 0
        items = try container.decodeIfPresent([String: ListeningStatsItem].self, forKey: .items) ?? [:]
        days = try container.decodeIfPresent([String: Double].self, forKey: .days) ?? [:]
        dayOfWeek = try container.decodeIfPresent([String: Double].self, forKey: .dayOfWeek) ?? [:]
        today = try container.decodeIfPresent(Double.self, forKey: .today) ?? 0
        recentSessions = try container.decodeLossyArrayIfPresent(PlaybackSession.self, forKey: .recentSessions) ?? []
    }
}

/// Listening time for one library item in ``ListeningStats``.
public struct ListeningStatsItem: Sendable, Hashable, Codable {
    /// The library item ID, or `nil` for sessions that lost it.
    public var id: String?
    public var timeListening: Double
    /// The metadata saved with the item's first session.
    public var mediaMetadata: ListeningStatsMetadata?
    /// Declared by the server, but always omitted: sessions have no `lastUpdate`.
    public var lastUpdate: Int?

    public init(
        id: String? = nil, timeListening: Double = 0, mediaMetadata: ListeningStatsMetadata? = nil,
        lastUpdate: Int? = nil
    ) {
        self.id = id
        self.timeListening = timeListening
        self.mediaMetadata = mediaMetadata
        self.lastUpdate = lastUpdate
    }

    enum CodingKeys: String, CodingKey {
        case id, timeListening, mediaMetadata, lastUpdate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        timeListening = try container.decodeIfPresent(Double.self, forKey: .timeListening) ?? 0
        mediaMetadata = try? container.decodeIfPresent(ListeningStatsMetadata.self, forKey: .mediaMetadata)
        lastUpdate = try container.decodeIfPresent(Int.self, forKey: .lastUpdate)
    }
}

/// Display fields from a session's book or podcast metadata. The stats item doesn't say which
/// media type it is, so this keeps only the fields both need.
public struct ListeningStatsMetadata: Sendable, Hashable, Codable {
    public var title: String?
    public var subtitle: String?
    /// Book authors.
    public var authors: [Author]?
    /// Podcast author.
    public var author: String?

    public init(title: String? = nil, subtitle: String? = nil, authors: [Author]? = nil, author: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.authors = authors
        self.author = author
    }

    enum CodingKeys: String, CodingKey {
        case title, subtitle, authors, author
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        authors = try container.decodeLossyArrayIfPresent(Author.self, forKey: .authors)
        author = try container.decodeIfPresent(String.self, forKey: .author)
    }
}

/// A name and listening time (seconds) in the year stats' top lists.
public struct YearStatsNameTime: Sendable, Hashable, Codable {
    public var name: String
    public var time: Double

    public init(name: String, time: Double) {
        self.name = name
        self.time = time
    }
}

/// A genre and listening time (seconds) in the year stats' top lists.
public struct YearStatsGenreTime: Sendable, Hashable, Codable {
    public var genre: String
    public var time: Double

    public init(genre: String, time: Double) {
        self.genre = genre
        self.time = time
    }
}

/// The month with the most listening in ``UserYearStats``.
public struct YearStatsMonthTime: Sendable, Hashable, Codable {
    /// Zero-based, as in JavaScript: `0` is January.
    public var month: Int
    public var time: Double

    public init(month: Int, time: Double) {
        self.month = month
        self.time = time
    }
}

/// The longest book the user finished in the year.
public struct YearStatsBook: Sendable, Hashable, Codable {
    /// The book (media) ID, not the library item ID.
    public var id: String
    public var title: String?
    /// Seconds.
    public var duration: Double?
    /// An ISO 8601 date string, unlike the epoch milliseconds elsewhere: the server serialises
    /// a `Date` here.
    public var finishedAt: String?

    public init(id: String, title: String? = nil, duration: Double? = nil, finishedAt: String? = nil) {
        self.id = id
        self.title = title
        self.duration = duration
        self.finishedAt = finishedAt
    }
}

/// `GET /api/me/stats/year/:year` (server `utils/queries/userStats.getStatsForYear`). Times are
/// seconds; the server rounds them.
public struct UserYearStats: Sendable, Hashable, Codable {
    public var totalListeningSessions: Int
    public var totalListeningTime: Double
    public var totalBookListeningTime: Double
    public var totalPodcastListeningTime: Double
    /// Up to three, most listened first.
    public var topAuthors: [YearStatsNameTime]
    /// Up to three, most listened first. Genres containing "audiobook" are excluded.
    public var topGenres: [YearStatsGenreTime]
    public var mostListenedNarrator: YearStatsNameTime?
    public var mostListenedMonth: YearStatsMonthTime?
    public var numBooksFinished: Int
    public var numBooksListened: Int
    public var longestAudiobookFinished: YearStatsBook?
    /// Up to 25 library item IDs with covers, excluding ``finishedBooksWithCovers``.
    public var booksWithCovers: [String]
    /// Up to 5 library item IDs with covers.
    public var finishedBooksWithCovers: [String]

    public init(
        totalListeningSessions: Int = 0, totalListeningTime: Double = 0, totalBookListeningTime: Double = 0,
        totalPodcastListeningTime: Double = 0, topAuthors: [YearStatsNameTime] = [],
        topGenres: [YearStatsGenreTime] = [], mostListenedNarrator: YearStatsNameTime? = nil,
        mostListenedMonth: YearStatsMonthTime? = nil, numBooksFinished: Int = 0, numBooksListened: Int = 0,
        longestAudiobookFinished: YearStatsBook? = nil, booksWithCovers: [String] = [],
        finishedBooksWithCovers: [String] = []
    ) {
        self.totalListeningSessions = totalListeningSessions
        self.totalListeningTime = totalListeningTime
        self.totalBookListeningTime = totalBookListeningTime
        self.totalPodcastListeningTime = totalPodcastListeningTime
        self.topAuthors = topAuthors
        self.topGenres = topGenres
        self.mostListenedNarrator = mostListenedNarrator
        self.mostListenedMonth = mostListenedMonth
        self.numBooksFinished = numBooksFinished
        self.numBooksListened = numBooksListened
        self.longestAudiobookFinished = longestAudiobookFinished
        self.booksWithCovers = booksWithCovers
        self.finishedBooksWithCovers = finishedBooksWithCovers
    }

    enum CodingKeys: String, CodingKey {
        case totalListeningSessions, totalListeningTime, totalBookListeningTime, totalPodcastListeningTime
        case topAuthors, topGenres, mostListenedNarrator, mostListenedMonth, numBooksFinished, numBooksListened
        case longestAudiobookFinished, booksWithCovers, finishedBooksWithCovers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalListeningSessions = try container.decodeIfPresent(Int.self, forKey: .totalListeningSessions) ?? 0
        totalListeningTime = try container.decodeIfPresent(Double.self, forKey: .totalListeningTime) ?? 0
        totalBookListeningTime = try container.decodeIfPresent(Double.self, forKey: .totalBookListeningTime) ?? 0
        totalPodcastListeningTime =
            try container.decodeIfPresent(Double.self, forKey: .totalPodcastListeningTime) ?? 0
        topAuthors = try container.decodeLossyArrayIfPresent(YearStatsNameTime.self, forKey: .topAuthors) ?? []
        topGenres = try container.decodeLossyArrayIfPresent(YearStatsGenreTime.self, forKey: .topGenres) ?? []
        mostListenedNarrator = try container.decodeIfPresent(YearStatsNameTime.self, forKey: .mostListenedNarrator)
        mostListenedMonth = try container.decodeIfPresent(YearStatsMonthTime.self, forKey: .mostListenedMonth)
        numBooksFinished = try container.decodeIfPresent(Int.self, forKey: .numBooksFinished) ?? 0
        numBooksListened = try container.decodeIfPresent(Int.self, forKey: .numBooksListened) ?? 0
        longestAudiobookFinished = try container.decodeIfPresent(
            YearStatsBook.self, forKey: .longestAudiobookFinished)
        booksWithCovers = try container.decodeIfPresent([String].self, forKey: .booksWithCovers) ?? []
        finishedBooksWithCovers = try container.decodeIfPresent([String].self, forKey: .finishedBooksWithCovers) ?? []
    }
}

/// `GET /api/stats/year/:year`, admin only (server `utils/queries/adminStats.getStatsForYear`).
/// Book totals cover items added up to the end of the year. Times are seconds and sizes bytes;
/// `totalListeningTime` and `totalBooksDuration` are not rounded.
public struct ServerYearStats: Sendable, Hashable, Codable {
    public var numListeningSessions: Int
    public var numBooksAdded: Int
    public var numAuthorsAdded: Int
    public var totalBooksAddedSize: Int
    public var totalBooksAddedDuration: Double
    /// Up to 25 library item IDs with covers.
    public var booksAddedWithCovers: [String]
    public var totalBooksSize: Int
    public var totalBooksDuration: Double
    public var totalListeningTime: Double
    public var numBooks: Int
    public var topAuthors: [YearStatsNameTime]
    public var topNarrators: [YearStatsNameTime]
    public var topGenres: [YearStatsGenreTime]

    public init(
        numListeningSessions: Int = 0, numBooksAdded: Int = 0, numAuthorsAdded: Int = 0,
        totalBooksAddedSize: Int = 0, totalBooksAddedDuration: Double = 0, booksAddedWithCovers: [String] = [],
        totalBooksSize: Int = 0, totalBooksDuration: Double = 0, totalListeningTime: Double = 0, numBooks: Int = 0,
        topAuthors: [YearStatsNameTime] = [], topNarrators: [YearStatsNameTime] = [],
        topGenres: [YearStatsGenreTime] = []
    ) {
        self.numListeningSessions = numListeningSessions
        self.numBooksAdded = numBooksAdded
        self.numAuthorsAdded = numAuthorsAdded
        self.totalBooksAddedSize = totalBooksAddedSize
        self.totalBooksAddedDuration = totalBooksAddedDuration
        self.booksAddedWithCovers = booksAddedWithCovers
        self.totalBooksSize = totalBooksSize
        self.totalBooksDuration = totalBooksDuration
        self.totalListeningTime = totalListeningTime
        self.numBooks = numBooks
        self.topAuthors = topAuthors
        self.topNarrators = topNarrators
        self.topGenres = topGenres
    }

    enum CodingKeys: String, CodingKey {
        case numListeningSessions, numBooksAdded, numAuthorsAdded, totalBooksAddedSize, totalBooksAddedDuration
        case booksAddedWithCovers, totalBooksSize, totalBooksDuration, totalListeningTime, numBooks
        case topAuthors, topNarrators, topGenres
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        numListeningSessions = try container.decodeIfPresent(Int.self, forKey: .numListeningSessions) ?? 0
        numBooksAdded = try container.decodeIfPresent(Int.self, forKey: .numBooksAdded) ?? 0
        numAuthorsAdded = try container.decodeIfPresent(Int.self, forKey: .numAuthorsAdded) ?? 0
        totalBooksAddedSize = try container.decodeIfPresent(Int.self, forKey: .totalBooksAddedSize) ?? 0
        totalBooksAddedDuration = try container.decodeIfPresent(Double.self, forKey: .totalBooksAddedDuration) ?? 0
        booksAddedWithCovers = try container.decodeIfPresent([String].self, forKey: .booksAddedWithCovers) ?? []
        totalBooksSize = try container.decodeIfPresent(Int.self, forKey: .totalBooksSize) ?? 0
        totalBooksDuration = try container.decodeIfPresent(Double.self, forKey: .totalBooksDuration) ?? 0
        totalListeningTime = try container.decodeIfPresent(Double.self, forKey: .totalListeningTime) ?? 0
        numBooks = try container.decodeIfPresent(Int.self, forKey: .numBooks) ?? 0
        topAuthors = try container.decodeLossyArrayIfPresent(YearStatsNameTime.self, forKey: .topAuthors) ?? []
        topNarrators = try container.decodeLossyArrayIfPresent(YearStatsNameTime.self, forKey: .topNarrators) ?? []
        topGenres = try container.decodeLossyArrayIfPresent(YearStatsGenreTime.self, forKey: .topGenres) ?? []
    }
}
