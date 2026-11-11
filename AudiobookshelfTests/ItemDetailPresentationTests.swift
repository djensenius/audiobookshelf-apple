import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import Foundation
import Testing

@testable import Audiobookshelf

@MainActor
@Suite struct ItemDetailPresentationTests {
    private let locale = Locale(identifier: "en_US")

    private func loadedModel(_ item: ABSCore.LibraryItem) async -> ItemDetailModel {
        let model = ItemDetailModel(
            itemID: item.id, service: PreviewItemDetailService(item: item, behavior: .succeed), cache: ProgressCache())
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
        #expect(text.detail == "3h 20m remaining")
    }

    /// The template comes from the supplied locale too, not the app's language (English here).
    @Test func progressTextUsesTheSuppliedLanguage() throws {
        let german = Locale(identifier: "de_DE")
        let text = try #require(
            ItemDetailProgressText(
                fraction: 0.424, isFinished: false, timeRemaining: 3 * 3_600 + 20 * 60, finishedAt: nil, locale: german)
        )
        let duration = DurationStyle.elapsed(showSeconds: false).string(3 * 3_600 + 20 * 60, locale: german)
        #expect(text.detail == "\(duration) verbleibend")
    }

    @Test func progressIsClampedToOneHundredPercent() throws {
        let over = try #require(
            ItemDetailProgressText(
                fraction: 1.7, isFinished: false, timeRemaining: nil, finishedAt: nil, locale: locale))
        #expect(over.percent == "100%")
        #expect(over.detail == nil)
        #expect(
            ItemDetailProgressText(
                fraction: -0.2, isFinished: false, timeRemaining: nil, finishedAt: nil, locale: locale)
                == nil)
    }

    @Test func finishedShowsFullAndTheDate() throws {
        // Noon local time, so the day is the same in every time zone the tests run in.
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2025, month: 11, day: 1, hour: 12)))
        let text = try #require(
            ItemDetailProgressText(
                fraction: 0.3, isFinished: true, timeRemaining: nil, finishedAt: date, locale: locale))
        #expect(text.percent == "100%")
        #expect(text.detail == "Finished Nov 1, 2025")

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

    @Test func refreshFailureBannerSaysWhenTheItemIsGone() async {
        let service = ScriptedItemService(item: ItemDetailPreviewData.book)
        let model = ItemDetailModel(itemID: ItemDetailPreviewData.book.id, service: service, cache: ProgressCache())
        var gone = ItemDetailGoneState()
        func isGone() -> Bool {
            let snapshot = ItemDetailGoneState.Snapshot(model: model)
            gone.update(snapshot)
            return gone.isGone(snapshot)
        }
        await model.load()
        #expect(ItemDetailRefreshFailure(model: model, isGone: isGone()) == nil)

        await service.fail(with: APIError.timedOut)
        await model.load()
        #expect(!isGone())
        #expect(
            ItemDetailRefreshFailure(model: model, isGone: isGone())?.messageKey == "MessageItemDetailRefreshFailed")

        await service.fail(with: APIError.notFound)
        await model.load()
        #expect(isGone())
        #expect(ItemDetailRefreshFailure(model: model, isGone: isGone())?.messageKey == "MessageItemDetailNotFound")
    }

    @Test func goneItemStaysGoneUntilAReloadSucceeds() async throws {
        let service = ScriptedItemService(item: ItemDetailPreviewData.book)
        let model = ItemDetailModel(itemID: ItemDetailPreviewData.book.id, service: service, cache: ProgressCache())
        var gone = ItemDetailGoneState()
        func isGone() -> Bool {
            let snapshot = ItemDetailGoneState.Snapshot(model: model)
            gone.update(snapshot)
            return gone.isGone(snapshot)
        }
        await model.load()
        #expect(!isGone())
        await service.fail(with: APIError.notFound)
        await model.load()
        #expect(isGone())

        // Retry, held at the server: the banner hides, but Play stays disabled.
        await service.hold()
        let retry = Task { await model.load() }
        try await service.waitForHeldRequest()
        #expect(model.isLoading)
        #expect(ItemDetailRefreshFailure(model: model, isGone: isGone()) == nil)
        #expect(isGone())
        #expect(!ItemDetailPlayPresentation(button: model.playButton, isMissing: false, canPlay: !isGone()).isEnabled)

        // The retry fails another way: still gone, and the banner says so.
        await service.fail(with: APIError.timedOut)
        await service.release()
        await retry.value
        #expect(isGone())
        #expect(ItemDetailRefreshFailure(model: model, isGone: isGone())?.messageKey == "MessageItemDetailNotFound")

        // Another retry succeeds: Play is enabled again.
        await service.succeed()
        await service.hold()
        let success = Task { await model.load() }
        try await service.waitForHeldRequest()
        #expect(isGone())
        await service.release()
        await success.value
        #expect(!isGone())
        #expect(ItemDetailRefreshFailure(model: model, isGone: isGone()) == nil)
        #expect(ItemDetailPlayPresentation(button: model.playButton, isMissing: false, canPlay: !isGone()).isEnabled)
    }

    @Test func playFailureIgnoresCancellation() {
        #expect(ItemDetailPlayFailure(error: CancellationError()) == nil)
        #expect(
            ItemDetailPlayFailure(error: APIError.timedOut)?.message == APIError.timedOut.localizedDescription)
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
        #expect(rows.first { $0.labelKey == "LabelNarrators" }?.spokenText == nil)
    }

    @Test func durationIsSpokenInFull() async throws {
        let model = await loadedModel(ItemDetailPreviewData.book)
        let rows = ItemDetailMetadataRow.rows(for: try #require(model.details), locale: locale)
        let duration = try #require(rows.first { $0.labelKey == "LabelDuration" })
        #expect(duration.values == [.text("9h 6m", spoken: "9 hours, 6 minutes")])
        #expect(duration.spokenText == "9 hours, 6 minutes")
    }

    @Test func singleNamesUseSingularLabels() async throws {
        let item = ItemDetailPreviewData.makeBook(
            authors: [Author(id: "aut_1", name: "One"), Author(id: "aut_2", name: "Two")], narrators: ["Solo"])
        let model = await loadedModel(item)
        let labels = ItemDetailMetadataRow.rows(for: try #require(model.details), locale: locale).map(\.labelKey)
        #expect(labels.contains("LabelAuthors"))
        #expect(!labels.contains("LabelAuthor"))
        #expect(labels.contains("LabelNarrator"))
        #expect(!labels.contains("LabelNarrators"))
    }

    @Test func duplicateNarratorsAreKept() async throws {
        let model = await loadedModel(ItemDetailPreviewData.makeBook(narrators: ["Echo", "Echo"]))
        let rows = ItemDetailMetadataRow.rows(for: try #require(model.details), locale: locale)
        let link = ItemDetailMetadataRow.Value.link("Echo", .libraryFilter(kind: .narrators, value: "Echo"))
        #expect(rows.first { $0.labelKey == "LabelNarrators" }?.values == [link, link])
    }

    @Test func zeroSizeIsLeftOut() async throws {
        let model = await loadedModel(ItemDetailPreviewData.makeBook(size: 0))
        let labels = ItemDetailMetadataRow.rows(for: try #require(model.details), locale: locale).map(\.labelKey)
        #expect(!labels.contains("LabelSize"))
    }

    @Test func metadataLeavesOutEmptyRows() async throws {
        let model = await loadedModel(ItemDetailPreviewData.ebookOnly)
        let details = try #require(model.details)
        #expect(ItemDetailMetadataRow.rows(for: details, locale: locale).map(\.labelKey) == ["LabelAuthor"])
    }
}

/// Serves the item, or fails, as the test scripts it; ``hold()`` keeps the next request
/// pending until ``release()``.
private actor ScriptedItemService: ItemDetailService {
    let item: ABSCore.LibraryItem
    private var error: (any Error)?
    private var isHolding = false
    private var held: CheckedContinuation<Void, Never>?

    init(item: ABSCore.LibraryItem) {
        self.item = item
    }

    func fail(with error: any Error) {
        self.error = error
    }

    func succeed() {
        error = nil
    }

    func hold() {
        isHolding = true
    }

    func release() {
        isHolding = false
        held?.resume()
        held = nil
    }

    /// Waits until a request is held.
    func waitForHeldRequest() async throws {
        var attempts = 0
        while held == nil, attempts < 1_000 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(held != nil)
    }

    func item(id: String) async throws -> ABSCore.LibraryItem {
        if isHolding {
            await withCheckedContinuation { held = $0 }
        }
        if let error { throw error }
        return item
    }
}
