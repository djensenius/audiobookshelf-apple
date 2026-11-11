import ABSAppModel
import ABSCore
import ABSUI
import Foundation

/// The library's series list, by name, a page at a time.
typealias SeriesListModel = ItemListModel<String, SeriesSummary>

/// What the series screens decide, kept out of the views so app tests cover it.
enum SeriesPresentation {
    static let listMessages = BrowseMessages(
        failed: "MessageSeriesListLoadFailed", empty: "MessageNoSeries", systemImage: "rectangle.stack")
    static let detailMessages = BrowseMessages(
        failed: "MessageSeriesDetailLoadFailed", empty: "MessageNoItemsFound",
        notFound: "MessageSeriesDetailNotFound", systemImage: "rectangle.stack")

    /// The series list of the key's library and account, sorted by name.
    @MainActor
    static func makeList(key: BrowseModelKey, services: LibraryStoreServices) -> SeriesListModel {
        .series(service: services, libraryID: key.libraryID, connectionKey: key.connection)
    }

    /// The detail screen's state. The header shows once the series loaded, so loaded is never
    /// empty; a series without books says so under the header.
    @MainActor
    static func state(of model: SeriesDetailModel) -> BrowseScreenState {
        .resolve(
            .init(
                hasLoaded: model.detail != nil, hasContent: true, isLoading: model.isLoading,
                hasError: model.error != nil, isNotFound: model.isNotFound))
    }

    /// The label on a book's cover, like the legacy "#1"; `nil` without a sequence.
    static func sequenceBadge(_ sequence: String?) -> String? {
        guard let sequence = sequence?.trimmingCharacters(in: .whitespacesAndNewlines), !sequence.isEmpty else {
            return nil
        }
        return "#\(sequence)"
    }

    /// The card of a book in the series `seriesName`. VoiceOver reads the cover's sequence badge
    /// from the label's series part, which becomes this series and sequence as the badge shows it
    /// ("Barsoom, #2"): the book's own series text may name another series, and a collapsed
    /// sub-series has none.
    static func card(for book: SeriesBook, in seriesName: String) -> ItemSummary {
        let item = book.summary
        let sequence = book.sequence?.trimmingCharacters(in: .whitespacesAndNewlines)
        let seriesText =
            if let sequence, !sequence.isEmpty {
                L10n.string("LabelSeriesBookNumber", seriesName, sequence)
            } else {
                seriesName
            }
        return ItemSummary(
            id: item.id, itemID: item.itemID, episodeID: item.episodeID, seriesID: item.seriesID, kind: item.kind,
            title: item.title, subtitle: item.subtitle, seriesText: seriesText, duration: item.duration,
            bookCount: item.bookCount, cover: item.cover, isExplicit: item.isExplicit, isAbridged: item.isAbridged,
            isMissing: item.isMissing, hasAudio: item.hasAudio)
    }

    /// Where Continue Series goes: the details of the model's continue book, which offer Play.
    static func continueRoute(for book: SeriesBook) -> Route {
        .item(id: book.summary.itemID)
    }

    /// Continue Series as VoiceOver reads it: the action, then the book.
    static func continueAccessibilityLabel(for book: SeriesBook) -> String {
        [L10n.string("LabelContinueSeries"), book.summary.title].joined(separator: ", ")
    }
}
