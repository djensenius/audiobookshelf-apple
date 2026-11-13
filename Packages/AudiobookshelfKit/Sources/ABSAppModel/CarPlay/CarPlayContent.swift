import ABSCore
import Foundation

/// What CarPlay's templates allow (ADR 0004). The CarPlay delegate passes the system's values:
/// `min(12, CPListTemplate.maximumItemCount)` and `CPListTemplate.maximumSectionCount`, so this
/// target doesn't import CarPlay and tests can use small limits.
public struct CarPlayLimits: Sendable, Hashable {
    /// Rows in one list, across its sections, the "More…" row included. At least 2, so a page
    /// always has room for one row and "More…".
    public let maximumItemCount: Int
    /// Sections in one list. At least 1.
    public let maximumSectionCount: Int
    /// List templates in one tab's stack, its root included. At least 1. The deepest list the
    /// browse tree has (``CarPlayDestination/depth``) is 4, which leaves room for Now Playing
    /// under the default of 5.
    public let maximumDepth: Int

    public init(maximumItemCount: Int = 12, maximumSectionCount: Int = 12, maximumDepth: Int = 5) {
        self.maximumItemCount = max(2, maximumItemCount)
        self.maximumSectionCount = max(1, maximumSectionCount)
        self.maximumDepth = max(1, maximumDepth)
    }

    /// Lists trimmed to 12 rows (#79) within five levels.
    public static let standard = CarPlayLimits()
}

/// The localized texts the builder needs. ABSAppModel has no strings, so the delegate passes
/// them from the app's catalog.
public struct CarPlayLabels: Sendable, Hashable {
    public let continueListening: String
    public let libraries: String
    public let books: String
    public let podcasts: String
    public let series: String
    public let authors: String
    /// The Latest tab: a podcast library's newest episodes.
    public let latest: String
    /// The row that shows the next rows of a list, for example "More…".
    public let more: String

    public init(
        continueListening: String, libraries: String, books: String, podcasts: String, series: String,
        authors: String, latest: String, more: String
    ) {
        self.continueListening = continueListening
        self.libraries = libraries
        self.books = books
        self.podcasts = podcasts
        self.series = series
        self.authors = authors
        self.latest = latest
        self.more = more
    }
}

/// A list CarPlay can show, and where it sits in a tab's stack.
public enum CarPlayDestination: Sendable, Hashable {
    /// The Continue tab: the account's Continue Listening shelf.
    case continueListening
    /// The Library tab's root: the account's libraries.
    case libraries
    /// A library's categories: books (or podcasts), series and authors.
    case library(id: String, mediaType: MediaType)
    /// A library's items: books, collapsed series or podcasts.
    case items(libraryID: String)
    case series(libraryID: String)
    case authors(libraryID: String)
    case seriesBooks(libraryID: String, seriesID: String)
    case authorBooks(libraryID: String, authorID: String)
    case podcastEpisodes(libraryID: String, itemID: String)
    /// The Latest tab's root: a podcast library's newest episodes (#80).
    case latestEpisodes(libraryID: String)

    /// The list's level in its tab's stack; the tab's root is 1.
    public var depth: Int {
        switch self {
        case .continueListening, .libraries, .latestEpisodes: 1
        case .library: 2
        case .items, .series, .authors: 3
        case .seriesBooks, .authorBooks, .podcastEpisodes: 4
        }
    }

    /// The library the list belongs to, if any.
    public var libraryID: String? {
        switch self {
        case .continueListening, .libraries: nil
        case .library(let id, _): id
        case .items(let id), .series(let id), .authors(let id): id
        case .seriesBooks(let id, _), .authorBooks(let id, _), .podcastEpisodes(let id, _): id
        case .latestEpisodes(let id): id
        }
    }
}

/// One row of a CarPlay list: a text, an image and what tapping it does. Rows carry no
/// descriptive text (author, duration, …), which CarPlay's driving guidelines discourage.
public struct CarPlayRow: Sendable, Hashable, Identifiable {
    public enum Action: Sendable, Hashable {
        /// Pushes the destination's list.
        case open(CarPlayDestination)
        /// Plays the item through the app's playback entry point, then shows Now Playing.
        case play(itemID: String, episodeID: String?)
        /// Shows the same list again from `offset` (an index into the list's model items, those
        /// left out as rows included), in place: the template's sections are
        /// replaced, so paging never adds a level. The delegate loads more items first when the
        /// list needs them (``CarPlayContentBuilder/rowsNeeded(offset:)``).
        case more(CarPlayDestination, offset: Int)
    }

    public let id: String
    public let text: String
    /// `nil` when the row has no image.
    public let image: ImageKey?
    /// Listening progress from 0 to 1, for `CPListItem.playbackProgress`; `nil` when not shown.
    public let progress: Double?
    /// An item that can't be played (missing on the server, or without audio) is shown disabled.
    public let isEnabled: Bool
    public let action: Action

    public init(
        id: String, text: String, image: ImageKey? = nil, progress: Double? = nil, isEnabled: Bool = true,
        action: Action
    ) {
        self.id = id
        self.text = text
        self.image = image
        self.progress = progress
        self.isEnabled = isEnabled
        self.action = action
    }
}

public struct CarPlaySection: Sendable, Hashable, Identifiable {
    public let id: String
    public let header: String?
    public let rows: [CarPlayRow]

    public init(id: String, header: String? = nil, rows: [CarPlayRow]) {
        self.id = id
        self.header = header
        self.rows = rows
    }
}

/// The content of one `CPListTemplate`.
public struct CarPlayList: Sendable, Hashable {
    public let destination: CarPlayDestination
    public let title: String
    public let sections: [CarPlaySection]
    /// The index of the model item the page starts from, when the list is paged with "More…".
    public let offset: Int

    public init(destination: CarPlayDestination, title: String, sections: [CarPlaySection], offset: Int = 0) {
        self.destination = destination
        self.title = title
        self.sections = sections
        self.offset = offset
    }

    public var depth: Int { destination.depth }
    public var rows: [CarPlayRow] { sections.flatMap(\.rows) }
}
