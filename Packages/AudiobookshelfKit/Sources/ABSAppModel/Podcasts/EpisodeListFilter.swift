import ABSCore
import Foundation

/// Which of a podcast's episodes the episode list shows (legacy `EpisodesTable.vue`
/// `filterItems`). The raw value is the legacy `podcastEpisodesFilterBy` value.
///
/// Legacy's Downloaded filter waits for local downloads.
public enum EpisodeListFilter: String, Sendable, Hashable, CaseIterable {
    case all
    /// Not finished, including episodes never started. The legacy default.
    case incomplete
    /// Started and not finished (``ItemProgress/isInProgress``).
    case inProgress
    /// Finished.
    case complete

    /// Whether an episode with `progress` (`nil` when the user has none) is shown.
    ///
    /// In progress follows ``ItemProgress/isInProgress``, as Continue Listening and the item
    /// actions do; legacy also counted a progress record with nothing listened.
    public func includes(_ progress: ItemProgress?) -> Bool {
        switch self {
        case .all: true
        case .incomplete: progress?.isFinished != true
        case .inProgress: progress?.isInProgress == true
        case .complete: progress?.isFinished == true
        }
    }
}

/// What the episode list is sorted by (legacy `episodeSortItems`). The raw value is the legacy
/// `podcastEpisodesOrderBy` value. Legacy's file name sort waits for local downloads.
public enum EpisodeSortKey: String, Sendable, Hashable, CaseIterable {
    case publishedAt
    case title
    case season
    case episode
}

/// The episode list's filter and sort, saved once for every podcast as legacy did (in
/// `AppSettings.podcastEpisodeListPreferences`).
///
/// Stored values are never trusted: ``init(from:)`` replaces a missing, mistyped or unknown
/// field with its default and never throws, and ``init(json:)`` returns `nil` for text that is
/// not a JSON object.
public struct EpisodeListPreferences: Sendable, Hashable, Codable {
    public var filter: EpisodeListFilter
    public var sort: EpisodeSortKey
    /// Newest, last or highest first; `nil` until the user picks a direction, so each podcast
    /// uses the default of ``isDescending(podcastType:)``.
    public var descending: Bool?

    /// The legacy defaults: incomplete episodes by published date, in the podcast's direction.
    public init(
        filter: EpisodeListFilter = .incomplete, sort: EpisodeSortKey = .publishedAt, descending: Bool? = nil
    ) {
        self.filter = filter
        self.sort = sort
        self.descending = descending
    }

    /// The direction for a podcast whose `metadata.type` is `podcastType`: the user's choice, else
    /// newest first for episodic podcasts and oldest first otherwise (legacy `sortDesc`).
    public func isDescending(podcastType: String?) -> Bool {
        descending ?? (podcastType == "episodic")
    }

    enum CodingKeys: String, CodingKey {
        case filter, sort, descending
    }

    public init(from decoder: any Decoder) throws {
        let defaults = EpisodeListPreferences()
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = defaults
            return
        }
        filter =
            (try? container.decode(String.self, forKey: .filter)).flatMap(EpisodeListFilter.init) ?? defaults.filter
        sort = (try? container.decode(String.self, forKey: .sort)).flatMap(EpisodeSortKey.init) ?? defaults.sort
        descending = try? container.decode(Bool.self, forKey: .descending)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(filter.rawValue, forKey: .filter)
        try container.encode(sort.rawValue, forKey: .sort)
        try container.encodeIfPresent(descending, forKey: .descending)
    }

    /// Decodes stored text; `nil` unless it is a JSON object.
    public init?(json: String) {
        guard let data = json.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) is [String: Any],
            let decoded = try? JSONDecoder().decode(EpisodeListPreferences.self, from: data)
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

/// Filters, searches and sorts a podcast's episodes (legacy `episodesFiltered` and
/// `episodesSorted`), and picks the one Next Episode plays.
public enum EpisodeList {
    /// The episodes that pass `filter` and whose title contains `search`, sorted by `sort`.
    ///
    /// - Search ignores case, diacritics and surrounding whitespace; an empty search matches all.
    /// - Text compares like legacy `localeCompare` with `numeric` and base sensitivity, so
    ///   "Episode 9" comes before "Episode 10".
    /// - A missing (or zero) published date counts as the oldest, as the legacy comment in
    ///   `episodesSorted` intends, and a blank season or episode number as higher than every
    ///   number, as legacy's `"undefined"` does. Like every value they follow the direction: missing
    ///   dates come first ascending and last descending, blank numbers the other way round.
    /// - Ties fall back to the other number and then the published date (season and episode
    ///   sorts) or to the published date (title sort), in the same direction, and finally to the
    ///   server's order, so the result is deterministic.
    ///
    /// - Parameter progress: The user's progress on an episode, `nil` when there is none.
    public static func arrange(
        _ episodes: [PodcastEpisode], filter: EpisodeListFilter, search: String = "", sort: EpisodeSortKey,
        descending: Bool, locale: Locale, progress: (PodcastEpisode) -> ItemProgress?
    ) -> [PodcastEpisode] {
        sorted(
            filtered(episodes, filter: filter, search: search, locale: locale, progress: progress), by: sort,
            descending: descending, locale: locale)
    }

    /// The episodes that pass `filter` and whose title contains `search`, in their order. Sorting
    /// before or after filtering gives the same list.
    static func filtered(
        _ episodes: [PodcastEpisode], filter: EpisodeListFilter, search: String, locale: Locale,
        progress: (PodcastEpisode) -> ItemProgress?
    ) -> [PodcastEpisode] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return episodes.filter { episode in
            guard filter.includes(progress(episode)) else { return false }
            return query.isEmpty || titleMatches(episode.title, query: query, locale: locale)
        }
    }

    /// The episode Next Episode plays (legacy `index.vue` `play()`): the first unfinished one,
    /// oldest first for serial podcasts and newest first otherwise, else the first of all;
    /// `nil` without episodes.
    public static func nextEpisode(
        _ episodes: [PodcastEpisode], podcastType: String?, locale: Locale,
        progress: (PodcastEpisode) -> ItemProgress?
    ) -> PodcastEpisode? {
        let ordered = sorted(episodes, by: .publishedAt, descending: podcastType != "serial", locale: locale)
        return ordered.first { progress($0)?.isFinished != true } ?? ordered.first
    }

    static func titleMatches(_ title: String, query: String, locale: Locale) -> Bool {
        title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
            != nil
    }

    static func sorted(
        _ episodes: [PodcastEpisode], by sort: EpisodeSortKey, descending: Bool, locale: Locale
    ) -> [PodcastEpisode] {
        episodes.enumerated()
            .sorted { lhs, rhs in
                let (first, second) = descending ? (rhs.element, lhs.element) : (lhs.element, rhs.element)
                let order = compare(first, second, by: sort, locale: locale)
                // The server's order breaks the remaining ties, whatever the direction.
                return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
            }
            .map(\.element)
    }

    /// The ascending order of two episodes by `sort` and its tie-breakers.
    static func compare(
        _ lhs: PodcastEpisode, _ rhs: PodcastEpisode, by sort: EpisodeSortKey, locale: Locale
    ) -> ComparisonResult {
        let keys: [EpisodeSortKey] =
            switch sort {
            case .publishedAt: [.publishedAt]
            case .title: [.title, .publishedAt]
            case .season: [.season, .episode, .publishedAt]
            case .episode: [.episode, .season, .publishedAt]
            }
        for key in keys {
            let order = compareKey(lhs, rhs, by: key, locale: locale)
            if order != .orderedSame { return order }
        }
        return .orderedSame
    }

    private static func compareKey(
        _ lhs: PodcastEpisode, _ rhs: PodcastEpisode, by key: EpisodeSortKey, locale: Locale
    ) -> ComparisonResult {
        switch key {
        case .publishedAt:
            // Missing (or 0, as legacy's `!aValue`) is the oldest.
            let (left, right) = (lhs.publishedAt ?? 0, rhs.publishedAt ?? 0)
            return left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        case .title:
            return compareText(lhs.title, rhs.title, locale: locale)
        case .season:
            return compareNumber(lhs.season, rhs.season, locale: locale)
        case .episode:
            return compareNumber(lhs.episode, rhs.episode, locale: locale)
        }
    }

    /// Season and episode numbers are free text; blank ones sort after the rest.
    private static func compareNumber(_ lhs: String?, _ rhs: String?, locale: Locale) -> ComparisonResult {
        let left = lhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let right = rhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (left.isEmpty, right.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): return compareText(left, right, locale: locale)
        }
    }

    private static func compareText(_ lhs: String, _ rhs: String, locale: Locale) -> ComparisonResult {
        lhs.compare(
            rhs, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive, .numeric], range: nil,
            locale: locale)
    }
}
