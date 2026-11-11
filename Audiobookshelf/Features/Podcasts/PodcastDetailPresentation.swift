import ABSAppModel
import ABSCore
import ABSUI
import Foundation

/// The words the podcast screen shows for its model's values (legacy `EpisodesTable.vue`,
/// `EpisodeRow.vue` and the podcast parts of `index.vue`). Built apart from the views so the
/// text can be tested.
enum PodcastDetailPresentation {
    /// The menu title of a filter.
    static func titleKey(for filter: EpisodeListFilter) -> String {
        switch filter {
        case .all: "LabelShowAll"
        case .incomplete: "LabelIncomplete"
        case .inProgress: "LabelInProgress"
        case .complete: "LabelComplete"
        }
    }

    /// The menu title of a sort.
    static func titleKey(for sort: EpisodeSortKey) -> String {
        switch sort {
        case .publishedAt: "LabelPubDate"
        case .title: "LabelTitle"
        case .season: "LabelSeason"
        case .episode: "LabelEpisode"
        }
    }

    static func directionKey(isDescending: Bool) -> String {
        isDescending ? "LabelPodcastDetailDescending" : "LabelPodcastDetailAscending"
    }

    /// The play button's text and what VoiceOver reads for it (legacy `timeRemaining`): the
    /// duration, the time left, or "Finished"; empty without a duration or with under a minute,
    /// which the duration style doesn't show.
    static func statusText(
        _ status: PodcastDetailModel.EpisodeStatus, locale: Locale
    ) -> (text: String, spoken: String) {
        let style = DurationStyle.elapsed(showSeconds: false)
        switch status {
        case .notStarted(let duration):
            guard let duration, !style.string(duration, locale: locale).isEmpty else { return ("", "") }
            return (style.string(duration, locale: locale), style.accessibilityString(duration, locale: locale))
        case .inProgress(let remaining):
            guard !style.string(remaining, locale: locale).isEmpty else { return ("", "") }
            return (
                L10n.string("LabelTimeRemaining", style.string(remaining, locale: locale), locale: locale),
                L10n.string("LabelTimeRemaining", style.accessibilityString(remaining, locale: locale), locale: locale)
            )
        case .finished:
            let finished = L10n.string("LabelFinished", locale: locale)
            return (finished, finished)
        }
    }

    /// "Published Mar 5, 2024" (legacy `MMM do, yyyy`); `nil` without a date.
    static func publishedText(_ publishedAt: Int?, locale: Locale) -> String? {
        guard let publishedAt, publishedAt > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(publishedAt) / 1_000)
        return L10n.string(
            "LabelPublishedDate", date.formatted(.dateTime.year().month(.abbreviated).day().locale(locale)),
            locale: locale)
    }

    /// The subtitle, else the description, as plain text; `nil` when both are blank.
    static func summaryText(_ episode: PodcastEpisode) -> String? {
        let html = [episode.subtitle, episode.description].lazy.compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let html else { return nil }
        let text = HTMLText.plainText(from: html).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// What VoiceOver reads of a ``summaryText(_:)``: its first sentence, cut after the last
    /// whole word within `limit` characters, with "…", when that is longer.
    static func spokenSummary(_ summary: String, limit: Int = 150) -> String {
        var sentence = summary
        summary.enumerateSubstrings(in: summary.startIndex..., options: .bySentences) { substring, _, _, stop in
            if let substring { sentence = substring.trimmingCharacters(in: .whitespacesAndNewlines) }
            stop = true
        }
        guard sentence.count > limit else { return sentence }
        let cut = sentence.index(sentence.startIndex, offsetBy: limit)
        var end: String.Index?
        sentence.enumerateSubstrings(in: sentence.startIndex..., options: [.byWords, .substringNotRequired]) {
            _, range, _, stop in
            if range.upperBound <= cut { end = range.upperBound } else { stop = true }
        }
        // A first word longer than the limit is cut where the limit falls.
        return sentence[..<(end ?? cut)] + "…"
    }

    /// The episode's badges: its number, season, and type unless it is a full episode.
    static func badges(_ episode: PodcastEpisode, locale: Locale) -> [String] {
        var badges: [String] = []
        if let number = nonEmpty(episode.episode) {
            badges.append(L10n.string("LabelPodcastDetailEpisodeNumber", number, locale: locale))
        }
        if let season = nonEmpty(episode.season) {
            badges.append(L10n.string("LabelPodcastDetailSeasonNumber", season, locale: locale))
        }
        switch episode.episodeType {
        case .trailer: badges.append(L10n.string("LabelPodcastDetailTrailer", locale: locale))
        case .bonus: badges.append(L10n.string("LabelPodcastDetailBonus", locale: locale))
        case .unknown(let raw):
            if let raw = nonEmpty(raw) { badges.append(raw.capitalized(with: locale)) }
        case .full, nil: break
        }
        return badges
    }

    /// `episodic` and `serial` in the user's language; other values capitalized, as legacy shows
    /// them.
    static func typeText(_ type: String, locale: Locale) -> String {
        switch type {
        case "episodic": L10n.string("LabelPodcastDetailEpisodic", locale: locale)
        case "serial": L10n.string("LabelPodcastDetailSerial", locale: locale)
        default: type.capitalized(with: locale)
        }
    }

    /// The header's metadata rows, in legacy order: author, type, genres and tags; genres and
    /// tags open the library filtered by them.
    @MainActor
    static func metadataRows(for model: PodcastDetailModel, locale: Locale) -> [ItemDetailMetadataRow] {
        var rows: [ItemDetailMetadataRow] = []
        func add(_ labelKey: String, _ values: [ItemDetailMetadataRow.Value]) {
            if !values.isEmpty { rows.append(ItemDetailMetadataRow(labelKey: labelKey, values: values)) }
        }
        add("LabelAuthor", model.author.map { [.text($0)] } ?? [])
        add("LabelType", model.podcastType.map { [.text(typeText($0, locale: locale))] } ?? [])
        add("LabelGenres", model.genres.map { .link($0, .libraryFilter(kind: .genres, value: $0)) })
        add("LabelTags", model.tags.map { .link($0, .libraryFilter(kind: .tags, value: $0)) })
        return rows
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// The actions of the podcast screen's episodes, performed as Home performs its card actions.
/// The only place the screen uses Home's helpers, so moving them changes one file.
enum PodcastEpisodeActions {
    /// The actions an episode's row offers: Play and the finished toggle, as legacy's rows did;
    /// none when the podcast is gone from the server. The row itself opens the episode.
    static func available(
        for summary: ItemSummary?, progress: ItemProgress?, context: ItemActionContext, isGone: Bool
    ) -> [ItemAction] {
        guard let summary, !isGone else { return [] }
        let offered: Set<ItemActionKind> = [.play, .markFinished, .markNotFinished]
        return ItemAction.available(for: summary, progress: progress, context: context)
            .filter { offered.contains($0.kind) }
    }

    static func context(canPlay: Bool) -> ItemActionContext {
        ItemCardActions.actionContext(canPlay: canPlay)
    }

    /// Performs `kind` on the episode `summary` stands for. A finished episode plays from the
    /// start, as the book screen's Play Again does.
    ///
    /// - Returns: The key of the message to show when the action failed.
    @MainActor
    static func perform(
        _ kind: ItemActionKind, on summary: ItemSummary, isFinished: Bool, actions: any ItemActionPerforming,
        play: PlayItemAction?
    ) async -> String? {
        let play = play.map { play in
            isFinished
                ? PlayItemAction { itemID, episodeID, _ in
                    try await play(itemID: itemID, episodeID: episodeID, startTime: 0)
                } : play
        }
        return await ItemCardActions.perform(kind, on: summary, actions: actions, play: play)
    }
}
