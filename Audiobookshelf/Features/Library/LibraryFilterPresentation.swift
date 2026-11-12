import ABSAppModel
import ABSCore
import ABSUI
import Foundation

/// What a filter route's screen (``Route/libraryFilter(kind:value:)``, ``Route/narrator(name:)``) decides, kept out
/// of the view so app tests cover it.
enum LibraryFilterPresentation {
    /// The filter the route pins: shown and queried, never saved.
    static func filter(kind: LibraryFilterKind, value: String) -> LibraryViewPreferences.Filter {
        let group: LibraryFilterGroup =
            switch kind {
            case .narrators: .narrators
            case .tags: .tags
            case .genres: .genres
            }
        return LibraryViewPreferences.Filter(group: group, value: value)
    }

    /// The legacy label of the route's kind.
    static func labelKey(for kind: LibraryFilterKind) -> String {
        switch kind {
        case .narrators: "LabelNarrator"
        case .tags: "LabelTag"
        case .genres: "LabelGenre"
        }
    }

    /// The screen's title: "Narrator: Stephen Fry", "Tag: Favorites", "Genre: Fantasy".
    static func title(kind: LibraryFilterKind, value: String, locale: Locale? = nil) -> String {
        L10n.string("HeaderLibraryFilterRoute", L10n.string(labelKey(for: kind), locale: locale), value, locale: locale)
    }

    /// The messages of a library of `mediaType` with the pinned filter. A filter the library's type can't query (a
    /// narrator in a podcast library) says there are no items, as the list is empty without asking the server.
    @MainActor
    static func messages(for model: LibraryItemsModel) -> BrowseMessages {
        let messages = LibraryPresentation.messages(for: model.mediaType)
        guard model.isFilterUnsupported else { return messages }
        return BrowseMessages(failed: messages.failed, empty: "MessageNoItemsFound", systemImage: messages.systemImage)
    }

    /// The model key of the route in `libraryID`: one model per library, account and filter.
    @MainActor
    static func modelKey(
        store: LibraryStore?, libraryID: String?, kind: LibraryFilterKind, value: String
    ) -> BrowseModelKey? {
        BrowseModelKey(store: store, libraryID: libraryID, entityID: "\(kind.rawValue):\(value)")
    }

    /// Where the screen sits for ⌘R and ⌥⌘F: the route on top of the stack. A saved scene's legacy
    /// ``Route/narrator(name:)`` opens the same screen, so it counts when it is the top route.
    static func placement(kind: LibraryFilterKind, value: String, topRoute: Route?) -> RefreshCommandPlacement {
        if kind == .narrators, topRoute == .narrator(name: value) { return .pushed(.narrator(name: value)) }
        return .pushed(.libraryFilter(kind: kind, value: value))
    }
}
