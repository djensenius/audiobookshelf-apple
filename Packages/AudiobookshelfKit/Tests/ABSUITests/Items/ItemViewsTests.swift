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
            ItemPresentation.accessibilityLabel(frankenstein) == "Frankenstein; or, The Modern Prometheus, Mary Shelley"
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

    private func renderedSize<V: View>(_ view: V, width: CGFloat, _ size: DynamicTypeSize) -> CGSize? {
        let renderer = ImageRenderer(
            content: view.frame(width: width).environment(\.dynamicTypeSize, size).environment(
                \.locale, Locale(identifier: "en_US")))
        guard let image = renderer.cgImage else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    @Test func viewsLayOutToANonZeroSizeAtNormalAndLargestTextSizes() throws {
        let serverID = UUID()
        let books = SampleLibrary.books.map { ItemSummary(item: $0) }
        let series = SeriesSummary(series: SampleLibrary.series[0])
        let author = AuthorSummary(author: SampleLibrary.authors[0])
        for size in [DynamicTypeSize.large, .accessibility5] {
            let card = ItemCard(item: books[2], serverID: serverID, progress: ItemProgress(fraction: 0.4)) { _ in }
            let row = ItemRow(item: books[2], serverID: serverID, progress: ItemProgress(fraction: 1, isFinished: true))
            { _ in }
            let shelf = ShelfRow(title: "Shelf", elements: books, onShowAll: {}) { item in
                ItemCard(item: item, serverID: serverID) { _ in }
            }
            let empty = ShelfRow(title: "Empty", elements: [ItemSummary]()) { item in
                ItemCard(item: item, serverID: serverID) { _ in }
            }
            let grid = ItemGrid(elements: books) { item in ItemCard(item: item, serverID: serverID) { _ in } }
            let seriesCard = SeriesCard(series: series, serverID: serverID) {}
            let authorCard = AuthorCard(author: author, serverID: serverID) {}
            let badge = ProgressBadge(progress: ItemProgress(fraction: 0.5))

            for (name, rendered) in [
                ("card", renderedSize(card, width: 160, size)),
                ("row", renderedSize(row, width: 360, size)),
                ("shelf", renderedSize(shelf, width: 360, size)),
                ("empty shelf", renderedSize(empty, width: 360, size)),
                ("grid", renderedSize(grid, width: 360, size)),
                ("series", renderedSize(seriesCard, width: 160, size)),
                ("author", renderedSize(authorCard, width: 120, size)),
                ("badge", renderedSize(badge, width: 40, size)),
            ] {
                let measured = try #require(rendered, "\(name) at \(size)")
                #expect(measured.width > 0 && measured.height > 0, "\(name) at \(size)")
            }
        }
    }
}
