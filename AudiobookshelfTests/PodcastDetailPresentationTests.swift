import ABSAPI
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

    /// The feed sheet's row ignores its children for VoiceOver, so the value carries everything
    /// the row shows besides the title, the subtitle included.
    @Test func feedEpisodeValueReadsWhatTheRowShows() throws {
        let full = try #require(
            RSSFeedEpisode(
                raw: .object([
                    "enclosure": .object(["url": .string("https://x/1.mp3")]), "title": .string("Pilot"),
                    "episode": .string("4"), "subtitle": .string("Where it all began."),
                    "publishedAt": .number(1_700_000_000_000),
                ])))
        let published = try #require(PodcastDetailPresentation.publishedText(full.publishedAt, locale: locale))
        #expect(
            PodcastFeedEpisodePresentation.accessibilityValue(full, isInLibrary: true, locale: locale)
                == "Episode #4, \(published), In library, Where it all began.")

        let bare = try #require(
            RSSFeedEpisode(raw: .object(["enclosure": .object(["url": .string("https://x/2.mp3")])])))
        #expect(PodcastFeedEpisodePresentation.accessibilityValue(bare, isInLibrary: false, locale: locale).isEmpty)
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

    @Test func voiceOverReadsTheFirstSentenceCutOnAWord() {
        #expect(PodcastDetailPresentation.spokenSummary("Short one. Then more.") == "Short one.")
        #expect(PodcastDetailPresentation.spokenSummary("No full stop") == "No full stop")
        #expect(PodcastDetailPresentation.spokenSummary("one two three", limit: 9) == "one two…")
        #expect(PodcastDetailPresentation.spokenSummary("one two three", limit: 7) == "one two…")
        #expect(PodcastDetailPresentation.spokenSummary("one two three", limit: 13) == "one two three")

        let words = (1...40).map { "word\($0)" }.joined(separator: " ")
        let spoken = PodcastDetailPresentation.spokenSummary(words + ". Next.")
        #expect(spoken.count <= 151)
        let kept = String(spoken.dropLast())
        #expect(spoken.hasSuffix("…"))
        #expect(words.hasPrefix(kept + " "))
        #expect(kept.count > 140)

        let long = String(repeating: "a", count: 200)
        #expect(PodcastDetailPresentation.spokenSummary(long) == String(repeating: "a", count: 150) + "…")
    }

    @Test func episodeRowsOfferPlayAndTheFinishedToggleUntilThePodcastIsGone() {
        let episode = ItemSummary(id: "e1", itemID: "li", episodeID: "e1", kind: .episode, title: "E", duration: 600)
        let context = PodcastEpisodeActions.context(canPlay: true)
        func kinds(_ progress: ItemProgress?, canPlay: Bool = true, isGone: Bool = false) -> [ItemActionKind] {
            PodcastEpisodeActions.available(
                for: episode, progress: progress, context: PodcastEpisodeActions.context(canPlay: canPlay),
                isGone: isGone
            ).map(\.kind)
        }
        // In progress: no Hide from Continue Listening, and the row opens the episode itself.
        #expect(kinds(ItemProgress(fraction: 0.5)) == [.play, .markFinished])
        #expect(kinds(ItemProgress(fraction: 1, isFinished: true)) == [.play, .markNotFinished])
        #expect(kinds(nil, canPlay: false) == [.markFinished])
        #expect(kinds(ItemProgress(fraction: 0.5), isGone: true).isEmpty)
        #expect(PodcastEpisodeActions.available(for: nil, progress: nil, context: context, isGone: false).isEmpty)
    }

    /// The shared controls of the podcast and Latest rows: Play's text, the finished toggle, the busy states and the
    /// progress bar.
    @Test func episodeRowControlsFollowStatusProgressAndBusyStates() {
        func state(
            _ status: PodcastDetailModel.EpisodeStatus, _ progress: ItemProgress?, actions: [ItemActionKind],
            starting: Bool = false, otherStarting: Bool = false, updating: Bool = false
        ) -> EpisodeRowControlsState {
            EpisodeRowControlsState(
                status: status, progress: progress, actions: actions, isStarting: starting,
                isOtherStarting: otherStarting, isUpdating: updating, locale: locale)
        }
        let fresh = state(.notStarted(duration: 1_800), nil, actions: [.play, .markFinished])
        #expect(fresh.playTitle == "30m")
        #expect(fresh.playSpoken == "30 minutes")
        #expect(fresh.canPlay && fresh.canToggle && !fresh.isFinished)
        #expect(fresh.toggle == .markFinished)
        #expect(fresh.toggleTitle == L10n.string("MessageMarkAsFinished"))
        #expect(fresh.toggleSystemImage == "checkmark.circle")
        #expect(fresh.progressFraction == nil)

        // Under a minute the button just says Play Episode.
        #expect(state(.notStarted(duration: 20), nil, actions: [.play]).playTitle == L10n.string("ButtonPlayEpisode"))

        let listening = state(
            .inProgress(remaining: 840), ItemProgress(fraction: 0.6), actions: [.play, .markFinished], starting: true)
        #expect(listening.playTitle == "14m remaining")
        #expect(listening.progressFraction == 0.6)
        #expect(!listening.canPlay && listening.canToggle)
        #expect(!state(.finished, nil, actions: [.play], otherStarting: true).canPlay)

        let finished = state(
            .finished, ItemProgress(fraction: 1, isFinished: true), actions: [.play, .markNotFinished], updating: true)
        #expect(finished.playTitle == "Finished")
        #expect(finished.isFinished && finished.canPlay && !finished.canToggle)
        #expect(finished.toggle == .markNotFinished)
        #expect(finished.toggleTitle == L10n.string("SharedMarkAsNotFinished"))
        #expect(finished.toggleSystemImage == "checkmark.circle.fill")
        #expect(finished.progressFraction == nil)

        // A podcast gone from the server offers no actions, so nothing can be pressed.
        let gone = state(.notStarted(duration: 1_800), nil, actions: [])
        #expect(!gone.canPlay && !gone.canToggle)
    }

    @Test func aFinishedEpisodePlaysFromTheStart() async {
        let episode = ItemSummary(id: "e1", itemID: "li", episodeID: "e1", kind: .episode, title: "E")
        let played = PlayedStarts()
        let play = PlayItemAction { itemID, episodeID, startTime in played.starts.append((itemID, episodeID, startTime))
        }
        for isFinished in [true, false] {
            let failure = await PodcastEpisodeActions.perform(
                .play, on: episode, isFinished: isFinished, actions: NoOpItemActions(), play: play)
            #expect(failure == nil)
        }
        #expect(played.starts.map(\.0) == ["li", "li"])
        #expect(played.starts.map(\.1) == ["e1", "e1"])
        #expect(played.starts.map(\.2) == [0, nil])
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

/// What a test's player was asked to play: the item, episode and start time.
@MainActor
private final class PlayedStarts {
    var starts: [(String, String?, Double?)] = []
}
