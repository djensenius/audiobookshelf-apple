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

    /// Where Continue Series goes: the details of the model's continue book, which offer Play.
    static func continueRoute(for book: SeriesBook) -> Route {
        .item(id: book.summary.itemID)
    }

    /// Continue Series as VoiceOver reads it: the action, then the book.
    static func continueAccessibilityLabel(for book: SeriesBook) -> String {
        [L10n.string("LabelContinueSeries"), book.summary.title].joined(separator: ", ")
    }
}
