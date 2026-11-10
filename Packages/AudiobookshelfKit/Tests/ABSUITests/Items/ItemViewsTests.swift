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
                == "Frankenstein; or, The Modern Prometheus, Mary Shelley, Abridged"
        )
    }

    @Test func collapsedSeriesLabelSpeaksTheBookCount() {
        let item = ItemSummary(
            id: "series-s", itemID: "li", seriesID: "s", kind: .series, title: "Barsoom", bookCount: 3)
        #expect(ItemPresentation.accessibilityLabel(item) == "Barsoom, 3 books")
    }

    @Test func cardValueSpeaksProgressFinishedAndMissing() {
        let locale = Locale(identifier: "en_US")
        func value(_ item: ItemSummary, _ progress: ItemProgress?) -> String {
            ItemPresentation.accessibilityValue(item, progress: progress, locale: locale)
        }
        #expect(value(frankenstein, nil) == "")
        #expect(value(frankenstein, ItemProgress(fraction: 0)) == "")
        #expect(value(frankenstein, ItemProgress(fraction: 0.42)) == "Progress, 42%")
        #expect(value(frankenstein, ItemProgress(fraction: 1, isFinished: true)) == "Finished")
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

    @Test func podcastsAndEpisodesGetSquareCovers() {
        #expect(ItemPresentation.defaultShape(frankenstein) == .book)
        #expect(ItemPresentation.defaultShape(ItemSummary(item: SampleLibrary.episodeItems[0])) == .square)
        #expect(ItemPresentation.defaultShape(ItemSummary(item: SampleLibrary.podcast)) == .square)
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

    // macOS has no Dynamic Type, so these compare layouts that don't depend on the text size.
    @Test func cardHeightHoldsTheCoverTheTitleAndTheMissingIndicator() throws {
        let serverID = UUID()
        func card(_ item: ItemSummary) -> some View { ItemCard(item: item, serverID: serverID) { _ in } }
        let plain = try renderedSize(card(frankenstein), width: 160)
        // A 1.6 cover at 160 pt wide is 256 pt tall; the title and subtitle add to it.
        #expect(plain.width == 160 && plain.height > 256 + 20)
        let missing = try renderedSize(card(ItemSummary(item: SampleLibrary.missing)), width: 160)
        #expect(missing.height > plain.height)
    }

    @Test func squareCoversMakeShorterCardsThanBookCovers() throws {
        let serverID = UUID()
        func card(_ item: ItemSummary) -> some View { ItemCard(item: item, serverID: serverID) { _ in } }
        let book = try renderedSize(card(frankenstein), width: 160)
        let episode = try renderedSize(card(ItemSummary(item: SampleLibrary.episodeItems[0])), width: 160)
        #expect(episode.height < book.height)
    }

    @Test func aShelfWithItemsIsTallerThanAnEmptyOne() throws {
        let serverID = UUID()
        let books = SampleLibrary.books.map { ItemSummary(item: $0) }
        let full = try renderedSize(
            ShelfRow(title: "Shelf", elements: books) { ItemCard(item: $0, serverID: serverID) { _ in } }, width: 360)
        let empty = try renderedSize(
            ShelfRow(title: "Shelf", elements: [ItemSummary]()) { ItemCard(item: $0, serverID: serverID) { _ in } },
            width: 360)
        #expect(full.height > empty.height + 200)
    }

    @Test func seriesAndAuthorCardsAreTallerThanTheirCover() throws {
        let serverID = UUID()
        let series = try renderedSize(
            SeriesCard(series: SeriesSummary(series: SampleLibrary.series[0]), serverID: serverID) {}, width: 160)
        #expect(series.height > 256)
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

    // MARK: Explicit, abridged and missing are spoken

    @Test func labelSpeaksExplicitAndAbridgedOnlyWhenSet() {
        func label(explicit: Bool, abridged: Bool) -> String {
            ItemPresentation.accessibilityLabel(
                ItemSummary(
                    id: "i", itemID: "i", kind: .book, title: "T", subtitle: "A", seriesText: "S #1",
                    isExplicit: explicit, isAbridged: abridged))
        }
        #expect(label(explicit: false, abridged: false) == "T, A, S #1")
        #expect(label(explicit: true, abridged: false) == "T, A, S #1, Explicit")
        #expect(label(explicit: false, abridged: true) == "T, A, S #1, Abridged")
        #expect(label(explicit: true, abridged: true) == "T, A, S #1, Explicit, Abridged")
    }
}
