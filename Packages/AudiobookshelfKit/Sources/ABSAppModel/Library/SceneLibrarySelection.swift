import ABSCore
import Foundation

/// A scene's choice of library (S7a): keeps ``Router/libraryID`` in step with the shared
/// ``LibraryStore``. The scene calls ``reconcile(_:store:)`` whenever ``trigger(_:store:)``
/// changes, and ``select(_:router:store:)`` when the user picks a library.
///
/// - A scene without a library starts in the store's ``LibraryStore/initialLibraryID``. Until
///   the libraries have loaded it's unchecked, and kept with every section of its kind.
/// - Once ``LibraryStore/hasLoaded`` is set the library is checked again: one that no longer
///   exists falls back to the initial library, and one that does gets its kind and sections.
///   With no libraries at all the selection and library-scoped paths are cleared.
///   Checking a library that was never checked (restored or guessed), whether it is kept or
///   replaced, keeps the paths, such as a launch or deep link's, opened before then.
/// - A deep link's ``Router/pendingLibraryID`` is opened once loaded, or dropped when the user
///   has no such library.
/// - Only a user's pick is saved as the account's last library.
/// - Add podcast is hidden once the user is known not to be allowed to add podcasts
///   (`canAddPodcast` is `false`, see `User.canAddPodcasts`), as legacy `BookshelfNavBar.vue`
///   does; while the user is unknown (`nil`, such as offline) the section is kept. A known
///   permission applies before the libraries load too, or when loading them fails, with or
///   without a library, leaving the library unchecked; Add podcast shows again when the
///   permission becomes `true` or unknown. Once loaded, the library's own sections apply.
///
/// Nothing happens while the store serves another account than the router's.
@MainActor
public enum SceneLibrarySelection {
    /// What ``reconcile(_:store:)`` depends on; reconcile again when it changes.
    public struct Trigger: Hashable, Sendable {
        let connectionKey: LibraryConnectionKey?
        let hasLoaded: Bool
        let libraries: [LibraryEntry]
        let libraryID: String?
        let pendingLibraryID: String?
        let canAddPodcast: Bool?
    }

    struct LibraryEntry: Hashable, Sendable {
        let id: String
        let mediaType: MediaType
    }

    public static func trigger(_ router: Router, store: LibraryStore, canAddPodcast: Bool? = nil) -> Trigger {
        Trigger(
            connectionKey: store.connectionKey, hasLoaded: store.hasLoaded,
            libraries: store.libraries.map { LibraryEntry(id: $0.id, mediaType: $0.mediaType) },
            libraryID: router.libraryID,
            pendingLibraryID: router.pendingLibraryID, canAddPodcast: canAddPodcast)
    }

    /// Applies the store's libraries to the router; see ``SceneLibrarySelection``.
    public static func reconcile(_ router: Router, store: LibraryStore, canAddPodcast: Bool? = nil) {
        guard isServing(router: router, store: store) else { return }
        guard store.hasLoaded else {
            // Unchecked until the libraries load: keep every section of the library's kind.
            if router.libraryID == nil, let initial = store.initialLibraryID {
                router.restoreLibrary(id: initial, kind: nil)
            }
            router.withholdSections(canAddPodcast == false ? [.addPodcast] : [])
            return
        }
        // The library's sections below include the permission.
        router.withholdSections([])
        if let pending = router.pendingLibraryID {
            if let library = store.libraries.first(where: { $0.id == pending }) {
                show(library, in: router, canAddPodcast: canAddPodcast)
                return
            }
            router.cancelLibraryRequest()
        }
        if let current = router.libraryID, let library = store.libraries.first(where: { $0.id == current }) {
            // An unchecked library that still exists may have had a launch or deep link opened
            // in a section its kind lacks; keep the paths as for a replaced guess.
            if !router.isLibraryChecked {
                adopt(library, in: router, canAddPodcast: canAddPodcast)
            } else {
                show(library, in: router, canAddPodcast: canAddPodcast)
            }
        } else if let initial = store.initialLibraryID,
            let library = store.libraries.first(where: { $0.id == initial })
        {
            if !router.isLibraryChecked {
                // The gone library was only restored or guessed, never checked, so the paths
                // weren't opened in it: for example a launch or deep link before the libraries
                // loaded. Replace it without resetting them.
                adopt(library, in: router, canAddPodcast: canAddPodcast)
            } else {
                show(library, in: router, canAddPodcast: canAddPodcast)
            }
        } else if router.libraryID != nil || !router.isLibraryChecked {
            // The user has no libraries: drop the stale selection so screens reach their
            // empty state.
            router.clearLibrary()
        }
    }

    /// Whether `store` serves the account `router` belongs to. During an account switch a
    /// scene's router can still belong to the old account while the store already serves the
    /// new one; nothing of the store should be shown then.
    public static func isServing(router: Router, store: LibraryStore) -> Bool {
        guard let key = store.connectionKey else { return false }
        return key.serverID == router.serverID && key.userID == router.userID
    }

    /// The user picked `libraryID`: shows it and saves it as the account's last library.
    public static func select(_ libraryID: String, router: Router, store: LibraryStore, canAddPodcast: Bool? = nil) {
        guard isServing(router: router, store: store),
            let library = store.libraries.first(where: { $0.id == libraryID })
        else {
            return
        }
        show(library, in: router, canAddPodcast: canAddPodcast)
        store.saveLastLibraryID(libraryID)
    }

    /// The sections `library` shows: Add podcast only unless the user is known not to be allowed
    /// to add podcasts. Playlists is kept until the shell knows the user's playlists.
    static func sections(for library: Library, canAddPodcast: Bool?) -> Set<AppTab> {
        AppTab.sections(for: LibraryKind(library.mediaType), canAddPodcast: canAddPodcast ?? true, hasPlaylists: true)
    }

    private static func show(_ library: Library, in router: Router, canAddPodcast: Bool?) {
        let kind = LibraryKind(library.mediaType)
        let sections = sections(for: library, canAddPodcast: canAddPodcast)
        // Only on a change: the router is observed, and this runs on its changes. A request for
        // the library already shown is a change too: selecting it is what drops the request.
        guard
            router.libraryID != library.id || router.libraryKind != kind || router.supportedSections != sections
                || router.pendingLibraryID == library.id
        else {
            if !router.isLibraryChecked { router.isLibraryChecked = true }
            return
        }
        router.selectLibrary(id: library.id, kind: kind, supportedSections: sections)
    }

    /// Shows `library` in place of an unchecked guess, keeping the paths; sections it doesn't
    /// support are still repaired, but an unsupported Library section falls back to the default
    /// grid with its path, which may hold a launch link's screens.
    private static func adopt(_ library: Library, in router: Router, canAddPodcast: Bool?) {
        router.restoreLibrary(
            id: library.id, kind: LibraryKind(library.mediaType),
            supportedSections: sections(for: library, canAddPodcast: canAddPodcast))
        router.repairSections(supported: router.supportedSections, keepsLibraryPath: true)
        router.isLibraryChecked = true
    }
}
