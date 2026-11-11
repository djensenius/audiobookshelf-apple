import ABSAPI
import ABSAppModel
import ABSCore
import Foundation
import Testing

@testable import Audiobookshelf

@MainActor
@Suite struct ItemDetailPresentationTests {
    private let locale = Locale(identifier: "en_US")

    private func loadedModel(_ item: ABSCore.LibraryItem, progress: MediaProgress? = nil) async -> ItemDetailModel {
        let cache = ProgressCache()
        if let progress { cache.apply(progress) }
        let model = ItemDetailModel(
            itemID: item.id, service: PreviewItemDetailService(item: item, behavior: .succeed), cache: cache)
        await model.load()
        return model
    }

    // MARK: Play button

    @Test func playButtonLabels() {
        let play = ItemDetailPlayPresentation(button: .play, isMissing: false, canPlay: true)
        #expect(play == .init(button: .play, isMissing: false, canPlay: true))
        #expect(play.titleKey == "ButtonPlay")
        #expect(play.isEnabled)

        let resume = ItemDetailPlayPresentation(button: .resume, isMissing: false, canPlay: true)
        #expect(resume.titleKey == "ButtonItemDetailResume")
        #expect(resume.isEnabled)

        let again = ItemDetailPlayPresentation(button: .playAgain, isMissing: false, canPlay: true)
        #expect(again.titleKey == "ButtonItemDetailPlayAgain")
        #expect(again.systemImage == "arrow.counterclockwise")
        #expect(again.isEnabled)
    }

    @Test func playIsDisabledWithoutAudioOrPlayItem() {
        let noAudio = ItemDetailPlayPresentation(button: .unavailable, isMissing: false, canPlay: true)
        #expect(noAudio.titleKey == "ButtonPlay")
        #expect(!noAudio.isEnabled)

        let missing = ItemDetailPlayPresentation(button: .unavailable, isMissing: true, canPlay: true)
        #expect(missing.titleKey == "LabelMissing")
        #expect(!missing.isEnabled)

        for button in [ItemDetailModel.PlayButton.play, .resume, .playAgain] {
            #expect(!ItemDetailPlayPresentation(button: button, isMissing: false, canPlay: false).isEnabled)
        }
    }

    @Test func finishedInProgressAndNoAudioItems() async {
        let finished = await loadedModel(ItemDetailPreviewData.book, progress: ItemDetailPreviewData.finished)
        #expect(finished.playButton == .playAgain)
        #expect(finished.playStartTime == 0)

        let inProgress = await loadedModel(ItemDetailPreviewData.book, progress: ItemDetailPreviewData.inProgress)
        #expect(inProgress.playButton == .resume)
        #expect(inProgress.playStartTime == nil)

        let noAudio = await loadedModel(ItemDetailPreviewData.ebookOnly)
        #expect(noAudio.playButton == .unavailable)
        #expect(noAudio.hasEbook)
        #expect(!noAudio.hasAudio)
        let play = ItemDetailPlayPresentation(button: noAudio.playButton, isMissing: noAudio.isMissing, canPlay: true)
        #expect(!play.isEnabled)

        let missing = await loadedModel(SampleLibrary.missing)
        #expect(
            ItemDetailPlayPresentation(button: missing.playButton, isMissing: missing.isMissing, canPlay: true).titleKey
                == "LabelMissing")
    }

    // MARK: Progress

    @Test func noProgressShowsNothing() {
        #expect(
            ItemDetailProgressText(fraction: 0, isFinished: false, timeRemaining: nil, finishedAt: nil, locale: locale)
                == nil)
    }

    @Test func inProgressShowsPercentAndTimeRemaining() throws {
        let text = try #require(
            ItemDetailProgressText(
                fraction: 0.424, isFinished: false, timeRemaining: 3 * 3_600 + 20 * 60, finishedAt: nil, locale: locale)
        )
        #expect(text.percent == "42%")
        #expect(text.detail?.hasSuffix("remaining") == true)
        #expect(text.detail?.contains("3") == true)
    }

    @Test func finishedShowsFullAndTheDate() throws {
        let date = Date(timeIntervalSince1970: 1_762_000_000)
        let text = try #require(
            ItemDetailProgressText(
                fraction: 0.3, isFinished: true, timeRemaining: nil, finishedAt: date, locale: locale))
        #expect(text.percent == "100%")
        #expect(text.detail?.contains("2025") == true)

        let undated = try #require(
            ItemDetailProgressText(fraction: 1, isFinished: true, timeRemaining: nil, finishedAt: nil, locale: locale))
        #expect(undated.detail == nil)
    }

    // MARK: Errors

    @Test func notFoundIsOnlyA404() {
        #expect(ItemDetailLoadError.isNotFound(APIError.notFound))
        #expect(!ItemDetailLoadError.isNotFound(APIError.timedOut))
        #expect(!ItemDetailLoadError.isNotFound(CancellationError()))
        #expect(!ItemDetailLoadError.isNotFound(nil))
    }

    // MARK: Metadata

    @Test func metadataLinksOpenTheirRoutes() async throws {
        let model = await loadedModel(ItemDetailPreviewData.book)
        let details = try #require(model.details)
        let rows = ItemDetailMetadataRow.rows(for: details, locale: locale)

        #expect(
            rows.map(\.labelKey) == [
                "LabelAuthor", "LabelSeries", "LabelDuration", "LabelNarrators", "LabelGenres", "LabelTags",
                "LabelItemDetailPublisher", "LabelPublishYear", "LabelLanguage", "LabelSize",
            ])
        let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.labelKey, $0.values) })
        #expect(byLabel["LabelAuthor"] == [.link("Edgar Rice Burroughs", .author(id: "aut_burroughs"))])
        #expect(byLabel["LabelSeries"] == [.link("Barsoom #1", .series(id: "ser_barsoom"))])
        #expect(
            byLabel["LabelNarrators"] == [
                .link("Grover Gardner", .libraryFilter(kind: .narrators, value: "Grover Gardner")),
                .link("Stefan Rudnicki", .libraryFilter(kind: .narrators, value: "Stefan Rudnicki")),
            ])
        #expect(
            byLabel["LabelGenres"]?.first
                == .link("Science Fiction", .libraryFilter(kind: .genres, value: "Science Fiction")))
        #expect(
            byLabel["LabelTags"]?.first == .link("Public Domain", .libraryFilter(kind: .tags, value: "Public Domain")))
        #expect(byLabel["LabelPublishYear"] == [.text("1917")])
    }

    @Test func metadataLeavesOutEmptyRows() async throws {
        let model = await loadedModel(ItemDetailPreviewData.ebookOnly)
        let details = try #require(model.details)
        #expect(ItemDetailMetadataRow.rows(for: details, locale: locale).map(\.labelKey) == ["LabelAuthor"])
    }
}
