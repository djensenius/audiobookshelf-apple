import ABSAppModel
import ABSCore
import ABSUI
import Foundation
import Testing

@testable import Audiobookshelf

@MainActor
@Suite struct PodcastDetailPresentationTests {
    private let locale = Locale(identifier: "en_US")

    private func loadedModel(_ item: ABSCore.LibraryItem) async -> PodcastDetailModel {
        let detail = ItemDetailModel(
            itemID: item.id, service: PreviewItemDetailService(item: item, behavior: .succeed), cache: ProgressCache())
        await detail.load()
        return PodcastDetailModel(detail: detail, cache: ProgressCache(), settings: nil, locale: locale)
    }

    @Test func everyMenuTitleIsLocalized() {
        let keys =
            EpisodeListFilter.allCases.map(PodcastDetailPresentation.titleKey(for:))
            + EpisodeSortKey.allCases.map(PodcastDetailPresentation.titleKey(for:))
            + [true, false].map(PodcastDetailPresentation.directionKey(isDescending:))
        for key in keys {
            #expect(L10n.string(key) != key, "\(key)")
        }
        #expect(Set(keys).count == keys.count)
    }

    @Test func statusShowsDurationTimeLeftOrFinished() {
        let notStarted = PodcastDetailPresentation.statusText(.notStarted(duration: 1_800), locale: locale)
        #expect(notStarted.text == "30m")
        #expect(notStarted.spoken == "30 minutes")

        let inProgress = PodcastDetailPresentation.statusText(.inProgress(remaining: 12_000), locale: locale)
        #expect(inProgress.text == "3h 20m remaining")
        #expect(inProgress.spoken == "3 hours, 20 minutes remaining")

        let finished = PodcastDetailPresentation.statusText(.finished, locale: locale)
        #expect(finished.text == "Finished")
        #expect(finished.spoken == "Finished")
    }

    /// Without a duration, or under the minute the duration style shows, the button just says Play.
    @Test(arguments: [
        PodcastDetailModel.EpisodeStatus.notStarted(duration: nil), .notStarted(duration: 20),
        .inProgress(remaining: 0), .inProgress(remaining: 45),
    ])
    func statusIsEmptyWithoutAShowableTime(_ status: PodcastDetailModel.EpisodeStatus) {
        let text = PodcastDetailPresentation.statusText(status, locale: locale)
        #expect(text.text.isEmpty)
        #expect(text.spoken.isEmpty)
    }

    @Test func publishedDateNeedsAPositiveTimestamp() throws {
        #expect(PodcastDetailPresentation.publishedText(nil, locale: locale) == nil)
        #expect(PodcastDetailPresentation.publishedText(0, locale: locale) == nil)
        // Noon UTC on 5 March 2024, so the month and year hold in every time zone.
        let text = try #require(PodcastDetailPresentation.publishedText(1_709_640_000_000, locale: locale))
        #expect(text.hasPrefix("Published Mar "))
        #expect(text.hasSuffix(", 2024"))
    }

    @Test func summaryPrefersSubtitleThenPlainDescription() {
        let subtitle = PodcastEpisode(id: "1", subtitle: "Short", description: "<p>Long</p>")
        #expect(PodcastDetailPresentation.summaryText(subtitle) == "Short")
        let description = PodcastEpisode(id: "2", subtitle: "  ", description: "<p>The <b>long</b> one</p>")
        #expect(PodcastDetailPresentation.summaryText(description) == "The long one")
        #expect(PodcastDetailPresentation.summaryText(PodcastEpisode(id: "3", description: "<p> </p>")) == nil)
        #expect(PodcastDetailPresentation.summaryText(PodcastEpisode(id: "4")) == nil)
    }

    @Test func badgesShowNumberSeasonAndUnusualTypes() {
        let trailer = PodcastEpisode(id: "1", season: "2", episode: "10", episodeType: .trailer)
        #expect(PodcastDetailPresentation.badges(trailer, locale: locale) == ["Episode #10", "Season #2", "Trailer"])
        let bonus = PodcastEpisode(id: "2", episodeType: .bonus)
        #expect(PodcastDetailPresentation.badges(bonus, locale: locale) == ["Bonus"])
        let full = PodcastEpisode(id: "3", season: " ", episode: "", episodeType: .full)
        #expect(PodcastDetailPresentation.badges(full, locale: locale).isEmpty)
        let other = PodcastEpisode(id: "4", episodeType: .unknown("special"))
        #expect(PodcastDetailPresentation.badges(other, locale: locale) == ["Special"])
    }

    @Test func typeIsTranslatedOrCapitalized() {
        #expect(PodcastDetailPresentation.typeText("episodic", locale: locale) == "Episodic")
        #expect(PodcastDetailPresentation.typeText("serial", locale: locale) == "Serial")
        #expect(PodcastDetailPresentation.typeText("mini series", locale: locale) == "Mini Series")
    }

    @Test func metadataRowsFollowLegacyOrder() async {
        let model = await loadedModel(PodcastDetailPreviewData.podcast)
        let rows = PodcastDetailPresentation.metadataRows(for: model, locale: locale)
        #expect(rows.map(\.labelKey) == ["LabelAuthor", "LabelType", "LabelGenres", "LabelTags"])
        #expect(rows[0].values == [.text("Public Domain Players")])
        #expect(rows[1].values == [.text("Episodic")])
        #expect(
            rows[2].values == [
                .link("Fiction", .libraryFilter(kind: .genres, value: "Fiction")),
                .link("Drama", .libraryFilter(kind: .genres, value: "Drama")),
            ])
        #expect(rows[3].values == [.link("Weekly", .libraryFilter(kind: .tags, value: "Weekly"))])
    }

    @Test func metadataRowsSkipMissingValues() async {
        let model = await loadedModel(SampleLibrary.podcast)
        let rows = PodcastDetailPresentation.metadataRows(for: model, locale: locale)
        #expect(rows.map(\.labelKey) == ["LabelAuthor"])
    }
}
