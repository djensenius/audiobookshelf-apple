import ABSCore
import Foundation
import Observation

/// The podcast detail screen (legacy `pages/item/_id/index.vue` with a podcast and
/// `components/tables/podcast/EpisodesTable.vue`): the header values, the episode list with its
/// filter, sort and search, each episode's progress, and the episode Next Episode plays.
///
/// - Loading belongs to the wrapped ``ItemDetailModel``, which the item screen already loaded; the
///   podcast is read from it on every access, so a reload shows here.
/// - Progress is read from the ``ProgressCache`` on every access, per episode, so a view reading
///   one episode's progress invalidates when that episode's cache entry changes.
/// - The filter, sort and direction are saved in ``AppSettings`` as they change, once for every
///   podcast, as legacy did; the search is not saved.
///
/// Like ``ItemDetailModel``, it belongs to one item and account.
@MainActor
@Observable
public final class PodcastDetailModel {
    /// What the play button of an episode row shows (legacy `EpisodeRow.vue` `timeRemaining`).
    public enum EpisodeStatus: Sendable, Hashable {
        /// No progress, or nothing listened; the episode's duration when it has one.
        case notStarted(duration: TimeInterval?)
        /// Seconds left, never negative.
        case inProgress(remaining: TimeInterval)
        case finished
    }

    /// The item, its loading state and its refresh.
    public let detail: ItemDetailModel
    /// The words the list searches with; trimmed when used.
    public var searchText = ""
    /// The saved filter and sort.
    public private(set) var preferences: EpisodeListPreferences {
        didSet { if preferences != oldValue { settings?.podcastEpisodeListPreferences = preferences.json } }
    }

    @ObservationIgnored private let cache: ProgressCache
    @ObservationIgnored private let settings: AppSettings?
    @ObservationIgnored private let locale: Locale

    /// - Parameters:
    ///   - detail: The item's model, which loads it.
    ///   - cache: The account's progress, the same cache `detail` reads.
    ///   - settings: Where the filter and sort are saved; `nil` keeps them for this screen only.
    ///   - locale: How text is compared and searched.
    public init(
        detail: ItemDetailModel, cache: ProgressCache, settings: AppSettings?, locale: Locale = .autoupdatingCurrent
    ) {
        self.detail = detail
        self.cache = cache
        self.settings = settings
        self.locale = locale
        preferences =
            settings?.podcastEpisodeListPreferences.flatMap(EpisodeListPreferences.init(json:))
            ?? EpisodeListPreferences()
    }

    // MARK: Podcast

    public var itemID: String { detail.itemID }
    /// `nil` until loaded, and for items that aren't podcasts.
    public var podcast: Podcast? { detail.item?.podcast }
    public var title: String { podcast?.metadata.title ?? "" }
    public var author: String? { Self.nonEmpty(podcast?.metadata.author) }
    /// `metadata.type`, `episodic` or `serial`; `nil` when blank.
    public var podcastType: String? { Self.nonEmpty(podcast?.metadata.type) }
    public var genres: [String] { (podcast?.metadata.genres ?? []).compactMap(Self.nonEmpty) }
    public var tags: [String] { (podcast?.tags ?? []).compactMap(Self.nonEmpty) }
    /// HTML, for ABSUI's `HTMLText`.
    public var descriptionHTML: String? { Self.nonEmpty(podcast?.metadata.description) }
    public var isExplicit: Bool { podcast?.metadata.explicit ?? false }
    /// The cover, title and play target cells use; `nil` until loaded.
    public var summary: ItemSummary? { detail.summary }
    /// Every episode, in the server's order.
    public var allEpisodes: [PodcastEpisode] { podcast?.episodes ?? [] }

    // MARK: Episode list

    public var filter: EpisodeListFilter {
        get { preferences.filter }
        set { preferences.filter = newValue }
    }

    public var sort: EpisodeSortKey {
        get { preferences.sort }
        set { preferences.sort = newValue }
    }

    /// The list's direction: the user's choice, else the podcast type's default.
    public var isDescending: Bool {
        get { preferences.isDescending(podcastType: podcastType) }
        set { preferences.descending = newValue }
    }

    /// The episodes shown, filtered, searched and sorted. Rebuilt on every read: read it once.
    public var episodes: [PodcastEpisode] {
        EpisodeList.arrange(
            allEpisodes, filter: filter, search: searchText, sort: sort, descending: isDescending, locale: locale,
            progress: itemProgress(for:))
    }

    /// The filter or search hides episodes the podcast has, so the view can offer to clear them.
    public var canClearFilter: Bool {
        filter != .all || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Shows every episode again.
    public func clearFilter() {
        filter = .all
        searchText = ""
    }

    // MARK: Episodes

    /// The user's progress on `episode`. Reading it registers observation of that episode only.
    public func progress(for episode: PodcastEpisode) -> MediaProgress? {
        cache.progress(libraryItemID: itemID, episodeID: episode.id)
    }

    /// `progress(for:)` as cells show it.
    public func itemProgress(for episode: PodcastEpisode) -> ItemProgress? {
        progress(for: episode).map(ItemProgress.init)
    }

    /// The play button's text for `episode`.
    public func status(for episode: PodcastEpisode) -> EpisodeStatus {
        Self.status(for: episode, progress: progress(for: episode))
    }

    /// Finished; else nothing listened (legacy checks the progress first, so a record at `0`
    /// still shows the duration); else the progress's duration, or the episode's, minus the
    /// current time.
    public nonisolated static func status(for episode: PodcastEpisode, progress: MediaProgress?) -> EpisodeStatus {
        let duration = episode.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        guard let progress else { return .notStarted(duration: duration) }
        let display = ItemProgress(progress)
        if display.isFinished { return .finished }
        guard display.fraction > 0 else { return .notStarted(duration: duration) }
        let total = progress.duration > 0 ? progress.duration : (duration ?? 0)
        let remaining = total - progress.currentTime
        return .inProgress(remaining: remaining.isFinite ? max(remaining, 0) : 0)
    }

    /// The episode as the play and progress actions take it; `nil` until loaded.
    public func summary(for episode: PodcastEpisode) -> ItemSummary? {
        detail.item.map { ItemSummary(item: $0, episode: episode) }
    }

    /// The podcast can play: loaded, not missing or invalid on the server, and with episodes
    /// (legacy `showPlay`).
    public var canPlay: Bool {
        guard let item = detail.item, !item.isMissing, !item.isInvalid else { return false }
        return !allEpisodes.isEmpty
    }

    /// The episode Next Episode plays; see ``EpisodeList/nextEpisode(_:podcastType:locale:progress:)``.
    public var nextEpisode: PodcastEpisode? {
        guard canPlay else { return nil }
        return EpisodeList.nextEpisode(
            allEpisodes, podcastType: podcastType, locale: locale, progress: itemProgress(for:))
    }

    private nonisolated static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
