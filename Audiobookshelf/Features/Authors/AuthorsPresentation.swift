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

    /// The author's library when the model loads books from another one (an author opened from
    /// outside the selected library): the screen rebuilds the model there. `nil` when they match
    /// or the server didn't send the author's library.
    @MainActor
    static func otherLibraryID(of model: AuthorDetailModel) -> String? {
        guard let libraryID = model.detail?.libraryID, libraryID != model.libraryID else { return nil }
        return libraryID
    }

    /// The key to rebuild the author screen with once `host` loaded an author of another
    /// library, so the books come from the author's library; `nil` when no rebuild is needed.
    @MainActor
    static func authorLibraryKey(after host: BrowseModelHost<AuthorDetailModel>) -> BrowseModelKey? {
        otherLibraryID(of: host.model).map { host.key.inLibrary($0) }
    }

    /// The author screen's key: `authorLibrary` (from ``authorLibraryKey(after:)``) while it is
    /// for the same store, account and author as the selected library's `key`, else `key`.
    static func key(_ key: BrowseModelKey?, authorLibrary: BrowseModelKey?) -> BrowseModelKey? {
        guard let key, let authorLibrary, authorLibrary.store == key.store,
            authorLibrary.connection == key.connection, authorLibrary.entityID == key.entityID
        else { return key }
        return authorLibrary
    }

    /// The books' state under the author; loading while the model is about to move to the
    /// author's library, whose books these aren't.
    @MainActor
    static func booksState(of model: AuthorDetailModel) -> BrowseScreenState {
        otherLibraryID(of: model) == nil ? .resolve(list: model.books) : .loading
    }

    /// "12 books" under the author's name: the count for the books filter once known and from
    /// the author's library, else the author's own count; `nil` when neither is known.
    @MainActor
    static func bookCount(of model: AuthorDetailModel) -> String? {
        guard let detail = model.detail else { return nil }
        return bookCount(total: otherLibraryID(of: model) == nil ? model.books.total : nil, author: detail.summary)
    }

    /// The count line from the books filter's `total`, else the author's own count.
    static func bookCount(total: Int?, author: AuthorSummary) -> String? {
        (total ?? author.bookCount).map { L10n.string("SharedBookCount", $0.formatted()) }
    }
}
