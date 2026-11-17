import Foundation

/// An item of the Library menu (ADR 0004): one of the focused scene's account's libraries, which
/// ``LibraryCommand/select(_:router:store:canAddPodcast:)`` switches the scene to, as the library
/// picker does.
public struct LibraryCommandItem: Identifiable, Hashable, Sendable {
    /// The library's ID.
    public let id: String
    public let name: String
    /// The digit of the item's ⌥⌘ shortcut, 1 to 9, for the first nine libraries; `nil` after them.
    public let shortcutDigit: Int?
    /// Whether the scene shows this library, for the item's checkmark.
    public let isCurrent: Bool

    public init(id: String, name: String, shortcutDigit: Int?, isCurrent: Bool) {
        self.id = id
        self.name = name
        self.shortcutDigit = shortcutDigit
        self.isCurrent = isCurrent
    }
}

/// The Library menu's rules (ADR 0004), over the focused scene's ``Router`` and the shared
/// ``LibraryStore``; the app runs them, so they are testable.
///
/// - The items are the store's libraries, in server order (the library picker's), while it serves
///   the router's account (``SceneLibrarySelection/isServing(router:store:)``). With no signed-in
///   scene focused, during an account switch, or before the libraries load, there are none, and
///   the menu is hidden.
/// - The first nine take ⌥⌘1 to ⌥⌘9 in that order.
/// - Choosing one is the library picker's choice (``SceneLibrarySelection/select(_:router:store:canAddPodcast:)``):
///   the scene shows it, and it's saved as the account's last library.
@MainActor
public enum LibraryCommand {
    /// How many libraries take a shortcut: ⌥⌘1 to ⌥⌘9.
    public static let shortcutCount = 9

    /// The menu's items for `router`, the focused scene's router (`nil` without one); empty when
    /// the menu has nothing to offer.
    public static func items(router: Router?, store: LibraryStore?) -> [LibraryCommandItem] {
        guard let router, let store, SceneLibrarySelection.isServing(router: router, store: store) else { return [] }
        return store.libraries.enumerated().map { index, library in
            LibraryCommandItem(
                id: library.id, name: library.name,
                shortcutDigit: index < shortcutCount ? index + 1 : nil, isCurrent: library.id == router.libraryID)
        }
    }

    /// Switches `router`'s scene to the library `id`, as the library picker does; does nothing
    /// without a router or a store, or when the store doesn't serve the router's account or has no
    /// such library.
    public static func select(_ id: String, router: Router?, store: LibraryStore?, canAddPodcast: Bool? = nil) {
        guard let router, let store else { return }
        SceneLibrarySelection.select(id, router: router, store: store, canAddPodcast: canAddPodcast)
    }
}
