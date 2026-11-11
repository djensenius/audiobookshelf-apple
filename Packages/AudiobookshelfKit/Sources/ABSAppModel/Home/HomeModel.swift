import ABSCore
import Foundation
import Observation

/// Home's state for one scene: the personalized shelves of ``libraryID`` as ``HomeSection``s,
/// filtered by the store's ``LibraryStore/progress``.
///
/// Like ``PersonalizedShelvesModel``, a model belongs to one account: views create it per account
/// identity (ADR 0004's identity-keyed subtree, `.id(identity)`) and recreate it when the identity
/// changes.
///
/// Within that identity it follows changes: it creates its ``PersonalizedShelvesModel`` with
/// ``LibraryStore/makeShelves(libraryID:)`` and replaces it on the next ``load()`` or
/// ``refresh()`` once ``libraryID`` or the store's ``LibraryStore/connectionKey`` no longer
/// matches. Until then the old model's state isn't shown (``sections`` is empty and ``hasLoaded``
/// is `false`), and responses to the old model's requests are dropped. A ``load()`` or
/// ``refresh()`` while the store is cleared drops the old model. Without one, signing out and
/// back in to the same account (the same `connectionKey`) shows the old model's shelves again;
/// recreating the model per identity avoids that.
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
    ///
    /// Rebuilt from the shelves on every read, so read it once per view body.
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
