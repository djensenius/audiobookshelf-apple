import Foundation

/// A destination pushed onto a tab's `NavigationStack` (ADR 0004).
///
/// Routes carry only stable server IDs, never models, server addresses, tokens or user
/// names, so they are safe to store in scene restoration data and to restore later.
public enum Route: Hashable, Codable, Sendable {
    /// An item (legacy `pages/item/_id`).
    case item(id: String)
    /// A podcast episode (legacy `pages/item/_id/_episode`).
    case episode(itemID: String, episodeID: String)
    case series(id: String)
    case author(id: String)
    case narrator(name: String)
    /// The library filtered to one narrator, tag or genre, opened by tapping it on an item
    /// (legacy `pages/bookshelf/library` with a `filter` query). `value` is the unencoded name.
    case libraryFilter(kind: LibraryFilterKind, value: String)
    case collection(id: String)
    case playlist(id: String)
    /// The playback history of a book, or of one podcast episode when `episodeID` is set
    /// (legacy `pages/media/_id/history`). Without an episode it stores as before, so saved
    /// scenes still decode.
    case history(itemID: String, episodeID: String? = nil)
    case localFolder(id: String)
    case localItem(id: String)
    case downloadQueue
    case stats
    case logs
    case servers
    /// Settings, pushed from Account on iOS. The Mac uses its Settings scene instead.
    case settings
}

extension Route {
    /// The route as a router stores it: ``narrator(name:)`` becomes the library filtered by that
    /// narrator, which is the screen it opens.
    var canonical: Route {
        if case .narrator(let name) = self { return .libraryFilter(kind: .narrators, value: name) }
        return self
    }
}

/// The filter a ``Route/libraryFilter(kind:value:)`` opens. The raw values are the server's filter
/// groups and are stored in scene snapshots, so they must not change.
public enum LibraryFilterKind: String, Hashable, Codable, Sendable, CaseIterable {
    case narrators, tags, genres
}
