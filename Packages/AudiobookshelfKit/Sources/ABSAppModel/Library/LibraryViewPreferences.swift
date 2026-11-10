import ABSAPI
import ABSCore
import Foundation

/// A sort the library list can ask the server for. The raw value is the `sort` query value.
///
/// The sets per library type come from the server's `libraryItemsBookFilters.js` and
/// `libraryItemsPodcastFilters.js` (`getOrder`) and the legacy `OrderModal.vue`.
public enum LibrarySortKey: String, Sendable, Hashable, CaseIterable {
    case title = "media.metadata.title"
    case authorFirstLast = "media.metadata.authorName"
    case authorLastFirst = "media.metadata.authorNameLF"
    case publishedYear = "media.metadata.publishedYear"
    case addedAt = "addedAt"
    case size = "size"
    case duration = "media.duration"
    case fileCreated = "birthtimeMs"
    case fileModified = "mtimeMs"
    case progress = "progress"
    case progressStarted = "progress.createdAt"
    case progressFinished = "progress.finishedAt"
    case random = "random"
    /// Podcasts only.
    case podcastAuthor = "media.metadata.author"
    /// Podcasts only.
    case episodeCount = "media.numTracks"

    public static let bookKeys: [LibrarySortKey] = [
        .title, .authorFirstLast, .authorLastFirst, .publishedYear, .addedAt, .size, .duration, .fileCreated,
        .fileModified, .progress, .progressStarted, .progressFinished, .random,
    ]
    public static let podcastKeys: [LibrarySortKey] = [
        .title, .podcastAuthor, .addedAt, .size, .episodeCount, .fileCreated, .fileModified, .random,
    ]

    public static func keys(for mediaType: MediaType) -> [LibrarySortKey] {
        mediaType == .podcast ? podcastKeys : bookKeys
    }

    /// The sort a key of the other library type becomes (legacy `checkUpdateLibrarySortFilter`);
    /// a key with no counterpart becomes the title.
    fileprivate func repaired(for mediaType: MediaType) -> LibrarySortKey {
        if Self.keys(for: mediaType).contains(self) { return self }
        if mediaType == .podcast {
            switch self {
            case .authorFirstLast, .authorLastFirst: return .podcastAuthor
            case .duration: return .episodeCount
            default: return .title
            }
        }
        switch self {
        case .podcastAuthor: return .authorFirstLast
        case .episodeCount: return .duration
        default: return .title
        }
    }
}

/// A filter group of the library list. The raw value is the server's filter group.
public enum LibraryFilterGroup: String, Sendable, Hashable, CaseIterable {
    case genres, tags, series, authors, narrators, languages, progress, ebooks, issues
    case feedOpen = "feed-open"
    case explicit

    /// Whether the filter is `group.<value>` rather than the group alone.
    public var needsValue: Bool {
        switch self {
        case .issues, .feedOpen, .explicit: false
        default: true
        }
    }

    public static let bookGroups: [LibraryFilterGroup] = allCases
    /// The legacy filter sheet offers genres, tags, RSS feed open and explicit for podcasts.
    public static let podcastGroups: [LibraryFilterGroup] = [.genres, .tags, .feedOpen, .explicit]

    public static func groups(for mediaType: MediaType) -> [LibraryFilterGroup] {
        mediaType == .podcast ? podcastGroups : bookGroups
    }
}

public enum LibraryViewMode: String, Sendable, Hashable {
    case grid, list
}

/// How one library is shown: sort, filter, view mode and series collapsing. Stored per account
/// and library (see ``AppSettings/libraryViewPreferencesKey(serverID:userID:libraryID:)``).
///
/// Stored values are never trusted: ``init(from:)`` replaces any missing, mistyped or unknown
/// field with its default and never throws, and ``init(json:)`` returns `nil` for text that is not
/// a JSON object. Whether a sort or filter fits a library type is not checked here but when the
/// preferences are used; see ``resolved(for:)``.
public struct LibraryViewPreferences: Sendable, Hashable, Codable {
    public struct Filter: Sendable, Hashable {
        public var group: LibraryFilterGroup
        /// The unencoded value (an ID or name); `nil` for groups that take none.
        public var value: String?

        public init(group: LibraryFilterGroup, value: String? = nil) {
            self.group = group
            self.value = group.needsValue ? value : nil
        }

        public var libraryFilter: LibraryFilter { LibraryFilter(group: group.rawValue, value: value) }
    }

    public var sort: LibrarySortKey
    public var descending: Bool
    public var filter: Filter?
    public var viewMode: LibraryViewMode
    /// Shows each series as one item. Book libraries only.
    public var collapseSeries: Bool

    /// The legacy defaults (`store/user.js`): newest first, no filter, series not collapsed.
    /// `enableAltView` (``AppSettings/enableAltView``) is the legacy "not bookshelf view": text
    /// rows (`.list`); the bookshelf view of covers is `.grid`.
    public init(
        sort: LibrarySortKey = .addedAt, descending: Bool = true, filter: Filter? = nil,
        viewMode: LibraryViewMode = .grid, collapseSeries: Bool = false
    ) {
        self.sort = sort
        self.descending = descending
        self.filter = filter
        self.viewMode = viewMode
        self.collapseSeries = collapseSeries
    }

    public static func defaults(enableAltView: Bool) -> LibraryViewPreferences {
        LibraryViewPreferences(viewMode: enableAltView ? .list : .grid)
    }

    /// Chooses `key`: the same key flips the direction; another key sorts ascending, except that
    /// the date added starts newest first (legacy `OrderModal.vue`).
    public mutating func selectSort(_ key: LibrarySortKey) {
        if sort == key {
            descending.toggle()
        } else {
            sort = key
            descending = key == .addedAt
        }
    }

    // MARK: Repair

    /// The preferences as they apply to a library of `mediaType`, which are the stored ones
    /// unless they name something the type doesn't support:
    /// - a sort of the other type becomes its counterpart (author, duration and number of
    ///   episodes swap; anything else becomes the title) and keeps the direction;
    /// - a filter group the type doesn't offer is dropped (`nil`);
    /// - series collapsing is off for podcasts.
    ///
    /// Callers use the repaired value to query and to show; they save only what the user changes
    /// afterwards, so opening a podcast library doesn't overwrite a book library's choice.
    /// Unknown media types count as books, the server's default.
    public func resolved(for mediaType: MediaType) -> LibraryViewPreferences {
        var result = self
        result.sort = sort.repaired(for: mediaType)
        if let filter, !LibraryFilterGroup.groups(for: mediaType).contains(filter.group) {
            result.filter = nil
        }
        if mediaType == .podcast { result.collapseSeries = false }
        return result
    }

    // MARK: Query

    /// The query for the first page; the list model sets `page` and `limit`. The preferences are
    /// repaired for `mediaType` first. Collapsing is not sent while filtering by series, where the
    /// server ignores it.
    public func query(for mediaType: MediaType) -> LibraryQuery {
        let preferences = resolved(for: mediaType)
        return LibraryQuery(
            sort: preferences.sort.rawValue, descending: preferences.descending,
            filter: preferences.filter?.libraryFilter,
            collapseSeries: preferences.collapseSeries && preferences.filter?.group != .series)
    }

    // MARK: Coding

    enum CodingKeys: String, CodingKey {
        case sort, descending, filterGroup, filterValue, viewMode, collapseSeries
    }

    public init(from decoder: any Decoder) throws {
        let defaults = LibraryViewPreferences()
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = defaults
            return
        }
        sort = (try? container.decode(String.self, forKey: .sort)).flatMap(LibrarySortKey.init) ?? defaults.sort
        descending = (try? container.decode(Bool.self, forKey: .descending)) ?? defaults.descending
        viewMode =
            (try? container.decode(String.self, forKey: .viewMode)).flatMap(LibraryViewMode.init)
            ?? defaults.viewMode
        collapseSeries = (try? container.decode(Bool.self, forKey: .collapseSeries)) ?? defaults.collapseSeries
        let value = try? container.decode(String.self, forKey: .filterValue)
        if let group = (try? container.decode(String.self, forKey: .filterGroup)).flatMap(LibraryFilterGroup.init),
            !group.needsValue || value?.isEmpty == false
        {
            filter = Filter(group: group, value: value)
        } else {
            filter = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sort.rawValue, forKey: .sort)
        try container.encode(descending, forKey: .descending)
        try container.encodeIfPresent(filter?.group.rawValue, forKey: .filterGroup)
        try container.encodeIfPresent(filter?.value, forKey: .filterValue)
        try container.encode(viewMode.rawValue, forKey: .viewMode)
        try container.encode(collapseSeries, forKey: .collapseSeries)
    }

    /// The preferences from the stored text, or `nil` if it isn't a JSON object.
    public init?(json: String) {
        guard let data = json.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) is [String: Any],
            let decoded = try? JSONDecoder().decode(LibraryViewPreferences.self, from: data)
        else { return nil }
        self = decoded
    }

    /// The stored text: compact JSON with sorted keys.
    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension AppSettings {
    /// The preferences saved for a library, or `nil` if there are none or they can't be read; the
    /// caller then uses ``LibraryViewPreferences/defaults(enableAltView:)``.
    public func libraryViewPreferences(for key: LibraryConnectionKey, libraryID: String) -> LibraryViewPreferences? {
        libraryViewPreferencesJSON(serverID: key.serverID, userID: key.userID, libraryID: libraryID)
            .flatMap(LibraryViewPreferences.init(json:))
    }

    public func saveLibraryViewPreferences(
        _ preferences: LibraryViewPreferences?, for key: LibraryConnectionKey, libraryID: String
    ) {
        setLibraryViewPreferencesJSON(
            preferences?.json, serverID: key.serverID, userID: key.userID, libraryID: libraryID)
    }
}
