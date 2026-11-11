import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import Foundation

/// What the author screens decide, kept out of the views so app tests cover it.
enum AuthorsPresentation {
    static let listMessages = BrowseMessages(
        failed: "MessageAuthorsListLoadFailed", empty: "MessageAuthorsListEmpty", systemImage: "person.2")
    static let detailMessages = BrowseMessages(
        failed: "MessageAuthorDetailLoadFailed", empty: "MessageNoItemsFound",
        notFound: "MessageAuthorDetailNotFound", systemImage: "person")
    /// The failure of the author's books, under the author.
    static let booksFailedMessage = "MessageAuthorBooksLoadFailed"

    /// The author's books by title, like the legacy bookshelf's default sort. The model adds the
    /// `authors.<id>` filter and the paging.
    static let booksQuery = LibraryQuery(sort: LibrarySortKey.title.rawValue, descending: false)

    /// The author screen's model for the key's library and account.
    @MainActor
    static func makeDetail(authorID: String, key: BrowseModelKey, services: LibraryStoreServices)
        -> AuthorDetailModel
    {
        AuthorDetailModel(
            authorID: authorID, libraryID: key.libraryID, query: booksQuery, service: services,
            connectionKey: key.connection)
    }

    @MainActor
    static func state(of model: AuthorsModel) -> BrowseScreenState {
        .resolve(
            .init(
                hasLoaded: model.hasLoaded, hasContent: !model.authors.isEmpty, isLoading: model.isLoading,
                hasError: model.error != nil))
    }

    /// The author screen's state. The header shows once the author loaded, so loaded is never
    /// empty; the books have their own state under it (``BrowseScreenState/resolve(list:)``).
    @MainActor
    static func state(of model: AuthorDetailModel) -> BrowseScreenState {
        .resolve(
            .init(
                hasLoaded: model.detail != nil, hasContent: true, isLoading: model.isLoading,
                hasError: model.error != nil, isNotFound: model.isNotFound))
    }

    /// "12 books" under the author's name: the library's count for the books filter once known,
    /// else the author's own count; `nil` when neither is known.
    static func bookCount(total: Int?, author: AuthorSummary) -> String? {
        (total ?? author.bookCount).map { L10n.string("SharedBookCount", $0.formatted()) }
    }
}
