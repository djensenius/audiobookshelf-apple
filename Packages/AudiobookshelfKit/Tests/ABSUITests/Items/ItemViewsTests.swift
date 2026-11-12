import ABSCore
import Observation
import SwiftUI
import Synchronization
import Testing

@testable import ABSUI

@MainActor
@Observable
private final class FakeProgressEntry {
    var value: ItemProgress?
}

@MainActor
@Suite struct ItemViewsTests {
    private let frankenstein = ItemSummary(item: SampleLibrary.frankenstein)

    // MARK: Accessibility

    @Test func cardLabelSpeaksTitleSubtitleAndSeries() {
        let item = ItemSummary(item: SampleLibrary.godsOfMars)
        #expect(
            ItemPresentation.accessibilityLabel(item)
                == "The Gods of Mars, Edgar Rice Burroughs, Barsoom #2")
        #expect(
            ItemPresentation.accessibilityLabel(frankenstein)
                == "Frankenstein; or, The Modern Prometheus, Mary Shelley")
    }

    @Test func itemRowAccessibilityLabelSpeaksDuration() {
        let item = ItemSummary(
            id: "li_1", itemID: "li_1", kind: .book, title: "Dune", subtitle: "Frank Herbert",
            seriesText: "Dune Chronicles #1", duration: 3_690)
        #expect(
            ItemPresentation.rowAccessibilityLabel(item, locale: Locale(identifier: "en_US"))
                == "Dune, Frank Herbert, Dune Chronicles #1, 1 hour, 2 minutes")
    }

    @Test func collapsedSeriesLabelSpeaksTheBookCount() {
        let item = ItemSummary(
            id: "series-s", itemID: "li", seriesID: "s", kind: .series, title: "Barsoom", bookCount: 3)
        #expect(ItemPresentation.accessibilityLabel(item) == "Barsoom, 3 books")
    }

    /// One book isn't "1 books" (#319).
    @Test func bookCountIsPlural() {
        let english = Locale(identifier: "en_US")
        #expect(ItemPresentation.bookCount(1, locale: english) == "1 book")
        #expect(ItemPresentation.bookCount(0, locale: english) == "0 books")
        #expect(ItemPresentation.bookCount(2, locale: english) == "2 books")
        let series = ItemSummary(
            id: "series-s", itemID: "li", seriesID: "s", kind: .series, title: "Barsoom", bookCount: 1)
        #expect(ItemPresentation.subtitle(series) == "1 book")
    }

    @Test func cardValueSpeaksProgressFinishedAndMissing() {
        let locale = Locale(identifier: "en_US")
        func value(_ item: ItemSummary, _ progress: ItemProgress?) -> String {
            ItemPresentation.accessibilityValue(item, progress: progress, locale: locale)
        }
        // Frankenstein is abridged: the badge is spoken after the progress.
        #expect(value(frankenstein, nil) == "Abridged")
        #expect(value(frankenstein, ItemProgress(fraction: 0)) == "Abridged")
        #expect(value(frankenstein, ItemProgress(fraction: 0.42)) == "Progress, 42%, Abridged")
        #expect(value(frankenstein, ItemProgress(fraction: 1, isFinished: true)) == "Finished, Abridged")
        #expect(value(ItemSummary(item: SampleLibrary.missing), nil) == "Missing")
    }

    @Test func everyActionHasATitleAndASymbol() {
        for kind in ItemActionKind.allCases {
            #expect(!ItemPresentation.title(kind).isEmpty)
            #expect(ItemPresentation.title(kind) != "ButtonPlay")
            #expect(!ItemPresentation.systemImage(kind).isEmpty)
        }
        #expect(ItemPresentation.title(.markNotFinished) == "Mark as Not Finished")
    }

    @Test func gridColumnsGetWiderAtLargerTextSizes() {
        let sizes: [DynamicTypeSize] = [.large, .xxxLarge, .accessibility1, .accessibility5]
        let widths = sizes.map(ItemGridMetrics.minimumCellWidth)
        #expect(widths == widths.sorted() && Set(widths).count == 3)
    }

    // MARK: Per-key progress observation

    @Test func readingProgressInACellInvalidatesOnlyThatItem() {
        let first = FakeProgressEntry()
        let second = FakeProgressEntry()
        let entries = ["a": first, "b": second]
        let reader = ItemProgressReader { itemID, _ in entries[itemID]?.value }

        let invalidated = Mutex<[String]>([])
        for id in ["a", "b"] {
            withObservationTracking {
                _ = reader(itemID: id, episodeID: nil)
            } onChange: {
                invalidated.withLock { $0.append(id) }
            }
        }
        first.value = ItemProgress(fraction: 0.5)
        #expect(invalidated.withLock { $0 } == ["a"])
        second.value = ItemProgress(fraction: 0.1)
        #expect(invalidated.withLock { $0 } == ["a", "b"])
    }

    @Test func theDefaultReaderKnowsNoProgress() {
        #expect(ItemProgressReader.none(itemID: "a", episodeID: nil) == nil)
    }

    // MARK: Layout

    private func renderedSize<V: View>(_ view: V, width: CGFloat) throws -> CGSize {
        let renderer = ImageRenderer(
            content: view.frame(width: width).environment(\.locale, Locale(identifier: "en_US")))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        return CGSize(width: image.width, height: image.height)
    }

    /// A library with standard (1.6) book covers.
    private let standard = LibrarySettings(coverAspectRatio: 0)

    // macOS has no Dynamic Type, so these compare layouts that don't depend on the text size.
    @Test func cardHeightHoldsTheCoverTheTitleAndTheMissingIndicator() throws {
        let serverID = UUID()
        func card(_ item: ItemSummary) -> some View {
            ItemCard(item: item, serverID: serverID, librarySettings: standard) { _ in }
        }
        let plain = try renderedSize(card(frankenstein), width: 160)
        // A 1.6 cover at 160 pt wide is 256 pt tall; the title and subtitle add to it.
        #expect(plain.width == 160 && plain.height > 256 + 20)
        let missing = try renderedSize(card(ItemSummary(item: SampleLibrary.missing)), width: 160)
        #expect(missing.height > plain.height)
    }

    @Test func squareCoversMakeShorterCardsThanBookCovers() throws {
        let serverID = UUID()
        func card(_ item: ItemSummary, _ settings: LibrarySettings?) -> some View {
            ItemCard(item: item, serverID: serverID, librarySettings: settings) { _ in }
        }
        let book = try renderedSize(card(frankenstein, standard), width: 160)
        let episode = try renderedSize(card(ItemSummary(item: SampleLibrary.episodeItems[0]), standard), width: 160)
        #expect(episode.height < book.height)
        let squareBook = try renderedSize(card(frankenstein, LibrarySettings(coverAspectRatio: 1)), width: 160)
        #expect(squareBook.height < book.height)
    }

    @Test func aShelfWithItemsIsTallerThanAnEmptyOne() throws {
        let serverID = UUID()
        let books = SampleLibrary.books.map { ItemSummary(item: $0) }
        let full = try renderedSize(
            ShelfRow(title: "Shelf", elements: books) {
                ItemCard(item: $0, serverID: serverID, librarySettings: standard) { _ in }
            }, width: 360)
        let empty = try renderedSize(
            ShelfRow(title: "Shelf", elements: [ItemSummary]()) { ItemCard(item: $0, serverID: serverID) { _ in } },
            width: 360)
        #expect(full.height > empty.height + 200)
    }

    @Test func seriesCardKeepsGroupedCoversVisibleAndAuthorCardIsTallerThanItsCover() throws {
        let serverID = UUID()
        let seriesCoverSize = CGSize(width: 160, height: 128)
        let groupedCovers = GroupCoverView.layout(
            count: 3, size: seriesCoverSize, aspectRatio: CoverShape.book.aspectRatio)
        #expect(groupedCovers.step > 0)
        #expect(groupedCovers.coverWidth + groupedCovers.step * 2 == seriesCoverSize.width)

        let series = try renderedSize(
            SeriesCard(series: SeriesSummary(series: SampleLibrary.series[0]), serverID: serverID) {}, width: 160)
        #expect(series.height > seriesCoverSize.height + 20 && series.height < 256)
        let author = try renderedSize(
            AuthorCard(author: AuthorSummary(author: SampleLibrary.authors[0]), serverID: serverID) {}, width: 120)
        #expect(author.height > 150)
    }

    // MARK: Series have no progress

    @Test func aCollapsedSeriesShowsNoProgressEvenWhenItsFirstBookHasSome() {
        let series = ItemSummary(
            id: "series-s", itemID: "li_first", seriesID: "s", kind: .series, title: "Barsoom", bookCount: 3)
        let finished = ItemProgress(fraction: 1, isFinished: true)
        let reader = ItemProgressReader { itemID, _ in itemID == "li_first" ? finished : nil }
        #expect(ItemPresentation.progress(for: series, explicit: nil, reader: reader) == nil)
        #expect(ItemPresentation.progress(for: series, explicit: finished, reader: reader) == nil)
        let shown = ItemPresentation.progress(for: series, explicit: nil, reader: reader)
        #expect(
            ItemPresentation.accessibilityValue(series, progress: shown, locale: Locale(identifier: "en_US")) == "")
        // Books and episodes still read it.
        let book = ItemSummary(id: "li_first", itemID: "li_first", kind: .book, title: "B")
        #expect(ItemPresentation.progress(for: book, explicit: nil, reader: reader) == finished)
        #expect(
            ItemPresentation.progress(for: book, explicit: ItemProgress(fraction: 0.2), reader: reader)?.fraction == 0.2
        )
    }

    // MARK: Explicit, abridged and missing are spoken as values

    @Test func badgesAreSpokenInTheValueOnlyWhenSet() {
        let locale = Locale(identifier: "en_US")
        func item(explicit: Bool, abridged: Bool) -> ItemSummary {
            ItemSummary(
                id: "i", itemID: "i", kind: .book, title: "T", subtitle: "A", seriesText: "S #1",
                isExplicit: explicit, isAbridged: abridged)
        }
        func value(explicit: Bool, abridged: Bool, _ progress: ItemProgress? = nil) -> String {
            ItemPresentation.accessibilityValue(
                item(explicit: explicit, abridged: abridged), progress: progress, locale: locale)
        }
        #expect(ItemPresentation.accessibilityLabel(item(explicit: true, abridged: true)) == "T, A, S #1")
        #expect(value(explicit: false, abridged: false) == "")
        #expect(value(explicit: true, abridged: false) == "Explicit")
        #expect(value(explicit: false, abridged: true) == "Abridged")
        #expect(
            value(explicit: true, abridged: true, ItemProgress(fraction: 0.45)) == "Progress, 45%, Explicit, Abridged")
        #expect(
            value(explicit: true, abridged: false, ItemProgress(fraction: 1, isFinished: true)) == "Finished, Explicit")
    }

    // MARK: Series, authors and shelves

    @Test func seriesAndAuthorCardsSpeakNameAndBookCount() {
        let english = Locale(identifier: "en_US")
        let series = SeriesSummary(series: SampleLibrary.series[0])
        #expect(
            ItemPresentation.accessibilityLabel(series, locale: english)
                == "\(series.name), \(ItemPresentation.bookCount(series.bookCount, locale: english))")
        #expect(
            ItemPresentation.accessibilityLabel(SeriesSummary(id: "s", name: "Barsoom", bookCount: 1), locale: english)
                == "Barsoom, 1 book")
        #expect(
            ItemPresentation.accessibilityLabel(
                AuthorSummary(id: "a", name: "Mary Shelley", bookCount: 2), locale: english)
                == "Mary Shelley, 2 books")
        #expect(ItemPresentation.accessibilityLabel(AuthorSummary(id: "a", name: "Mary Shelley")) == "Mary Shelley")
    }

    @Test func showAllNamesItsShelf() {
        #expect(
            ItemPresentation.showAllAccessibilityLabel(shelfTitle: "Continue Listening")
                == "Show All, Continue Listening")
    }

    // MARK: Progress badge, colour and motion

    @Test func progressBadgeIsReadAsAValue() {
        let locale = Locale(identifier: "en_US")
        #expect(ItemPresentation.progressBadgeValue(nil, locale: locale) == nil)
        #expect(ItemPresentation.progressBadgeValue(ItemProgress(fraction: 0), locale: locale) == nil)
        #expect(ItemPresentation.progressBadgeValue(ItemProgress(fraction: 0.45), locale: locale) == "45%")
        #expect(
            ItemPresentation.progressBadgeValue(ItemProgress(fraction: 1, isFinished: true), locale: locale)
                == "Finished")
    }

    @Test func aFinishedCardAddsACheckWhenColourCannotTellIt() {
        let finished = ItemProgress(fraction: 1, isFinished: true)
        #expect(ItemPresentation.showsFinishedCheck(finished, differentiateWithoutColor: true))
        #expect(!ItemPresentation.showsFinishedCheck(finished, differentiateWithoutColor: false))
        #expect(!ItemPresentation.showsFinishedCheck(ItemProgress(fraction: 0.99), differentiateWithoutColor: true))
        #expect(!ItemPresentation.showsFinishedCheck(nil, differentiateWithoutColor: true))
    }

    @Test func theProgressRingMovesAtOnceWithReduceMotion() {
        #expect(ProgressRing.animation(reduceMotion: true) == nil)
        #expect(ProgressRing.animation(reduceMotion: false) != nil)
    }

    // MARK: Accessibility text sizes

    @Test func aRowStacksItsCoverAboveTheTextAtAccessibilitySizes() throws {
        let serverID = UUID()
        func row(_ size: DynamicTypeSize) -> some View {
            ItemRow(item: frankenstein, serverID: serverID) { _ in }.environment(\.dynamicTypeSize, size)
        }
        let large = try renderedSize(row(.large), width: 360)
        let huge = try renderedSize(row(.accessibility5), width: 360)
        #expect(huge.height > large.height + 40)
    }
}
