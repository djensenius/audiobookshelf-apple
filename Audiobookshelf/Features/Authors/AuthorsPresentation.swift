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

    /// The author's books by title, like the legacy bookshelf; the model adds the `authors.<id>` filter and paging.
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

    /// The author screen's state, never empty once the author loaded; the books have their own under the header.
    @MainActor
    static func state(of model: AuthorDetailModel) -> BrowseScreenState {
        .resolve(
            .init(
                hasLoaded: model.detail != nil, hasContent: true, isLoading: model.isLoading,
                hasError: model.error != nil, isNotFound: model.isNotFound))
    }

    /// "12 books": the books filter's `total` once known, else the author's own count; `nil` when neither is.
    static func bookCount(total: Int?, author: AuthorSummary) -> String? {
        (total ?? author.bookCount).map { L10n.plural("SharedBookCount", count: $0) }
    }

    /// Refreshes the author and their books for the user (pull to refresh, Refresh, Retry); `true` if either failed.
    @MainActor
    static func refresh(_ model: AuthorDetailModel) async -> Bool {
        await model.refresh()
        return model.error != nil || model.books.error != nil
    }

    /// Where a failure shows: above the author when it or a user refresh failed, after the books when only paging did.
    @MainActor
    static func failurePlacement(of model: AuthorDetailModel, refreshFailed: Bool)
        -> BrowsePresentation.ListFailurePlacement?
    {
        BrowsePresentation.failurePlacement(
            failed: model.error != nil || model.books.error != nil, refreshFailed: refreshFailed || model.error != nil)
    }
}
