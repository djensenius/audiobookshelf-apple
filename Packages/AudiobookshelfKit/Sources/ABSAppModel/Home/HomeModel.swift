import ABSCore
import Foundation
import Observation

/// Home's state for one scene: the personalized shelves of ``libraryID`` as ``HomeSection``s,
/// filtered by the store's ``LibraryStore/progress``.
///
/// The model creates its ``PersonalizedShelvesModel`` with ``LibraryStore/makeShelves(libraryID:)``
/// and replaces it on the next ``load()`` or ``refresh()`` once the store's ``LibraryStore/connectionKey``
/// or ``libraryID`` no longer matches. Until then a stale model's state is not shown: ``sections``
/// is empty and ``hasLoaded`` is `false`, so another account's shelves never appear.
@MainActor
@Observable
public final class HomeModel {
    /// The library to show; usually the scene's `Router.libraryID`. Changing it takes effect on
    /// the next ``load()`` or ``refresh()``.
    public var libraryID: String?

    @ObservationIgnored private let store: LibraryStore
    private var shelves: PersonalizedShelvesModel?

    public init(store: LibraryStore, libraryID: String? = nil) {
        self.store = store
        self.libraryID = libraryID
    }

    /// The sections in server order. Items hidden from Continue Listening or finished leave the
    /// continue shelves as soon as the progress cache has the change.
    public var sections: [HomeSection] {
        guard let shelves = current else { return [] }
        return HomeSection.sections(from: shelves.shelves) { [store] itemID, episodeID in
            store.progress.progress(libraryItemID: itemID, episodeID: episodeID)
        }
    }

    public var isLoading: Bool { current?.isLoading ?? false }
    /// Shelves have been loaded at least once for this library and account.
    public var hasLoaded: Bool { current?.hasLoaded ?? false }
    /// The error of the last load, cleared by the next successful one. Sections stay after a
    /// failed reload.
    public var error: (any Error)? { current?.error }

    /// Loads the shelves unless they are already loaded for this library and account, for
    /// example when Home appears.
    public func load() async {
        guard let shelves = currentOrNew(), !shelves.hasLoaded else { return }
        await shelves.load()
    }

    /// Reloads the shelves, for example on pull to refresh.
    public func refresh() async {
        await currentOrNew()?.load()
    }

    /// The shelves model for the current library and account, if it exists.
    private var current: PersonalizedShelvesModel? {
        guard let shelves, let libraryID, shelves.libraryID == libraryID,
            let connectionKey = store.connectionKey, shelves.connectionKey == connectionKey
        else { return nil }
        return shelves
    }

    private func currentOrNew() -> PersonalizedShelvesModel? {
        if let current { return current }
        shelves = libraryID.flatMap { store.makeShelves(libraryID: $0) }
        return shelves
    }
}
