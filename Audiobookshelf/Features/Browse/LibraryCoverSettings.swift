import ABSAppModel
import ABSCore
import SwiftUI

/// The library settings that decide the shape of book covers (``ABSUI/CoverShape/init(kind:librarySettings:)``),
/// read from the environment's `LibraryStore` and the scene's `Router`. Declare it as a view property:
///
/// ```swift
/// private var libraries = LibraryCoverSettings()
/// …
/// ItemCard(item: item, serverID: serverID, librarySettings: libraries.current)
/// ```
///
/// Both are `nil` while signed out (or before the libraries load), which gives the legacy default, square.
@MainActor
struct LibraryCoverSettings: DynamicProperty {
    @Environment(Router.self) private var router: Router?
    @Environment(\.libraryStore) private var store

    /// The scene's current library's settings.
    var current: LibrarySettings? { settings(forLibrary: nil) }

    /// `libraryID`'s settings when the store has that library, else the current library's.
    func settings(forLibrary libraryID: String?) -> LibrarySettings? {
        Self.settings(forLibrary: libraryID, current: router?.libraryID) { store?.library(id: $0) }
    }

    /// `libraryID`'s settings when `library` finds it, else those of the `current` library.
    nonisolated static func settings(
        forLibrary libraryID: String?, current: String?, library: (String) -> Library?
    ) -> LibrarySettings? {
        let found = libraryID.flatMap(library) ?? current.flatMap(library)
        return found?.settings
    }
}
