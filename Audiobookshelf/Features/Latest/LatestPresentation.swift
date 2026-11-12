import ABSAppModel
import ABSCore
import ABSUI
import Foundation

/// What the Latest screen decides, kept out of the views so app tests cover it.
enum LatestPresentation {
    static let messages = BrowseMessages(
        failed: "MessageLatestEpisodesLoadFailed", empty: "MessageNoLatestEpisodes",
        systemImage: AppTab.latest.systemImage)

    /// The latest episodes of the key's library and account, with the store's progress.
    @MainActor
    static func makeModel(key: BrowseModelKey, services: LibraryStoreServices, progress: ProgressCache)
        -> LatestEpisodesModel
    {
        LatestEpisodesModel(
            service: services, libraryID: key.libraryID, cache: progress, connectionKey: key.connection)
    }

    /// When the episode was published, relative to `now` like legacy's "3 days ago"; `nil` without a date.
    static func publishedText(_ publishedAt: Int?, now: Date, locale: Locale) -> String? {
        guard let publishedAt, publishedAt > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(publishedAt) / 1_000)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// Where Go to Podcast leads (legacy's podcast title linking to `/item/:libraryItemId`): the episode's podcast.
    static func podcastRoute(_ row: LatestEpisode) -> Route {
        .item(id: row.itemID)
    }

    /// The row's details as VoiceOver reads them after the episode's title: the podcast, "Explicit", when it was
    /// published, the badges and the start of the summary.
    static func detailsValue(
        _ row: LatestEpisode, published: String?, badges: [String], spokenSummary: String?
    ) -> String {
        let explicit = row.summary.isExplicit ? L10n.string("LabelExplicit") : nil
        return ([row.summary.subtitle, explicit, published] + badges.map(Optional.some) + [spokenSummary])
            .compactMap(\.self).joined(separator: ", ")
    }
}
