import ABSAppModel
import ABSCore
import ABSUI
import Foundation

/// The bookshelf of one library: its items as cards or rows, a page at a time.
typealias LibraryItemsModel = LibraryBrowseModel<ItemSummary>

/// The Library screen's model with the key it was built for.
typealias LibraryModelHost = BrowseModelHost<LibraryItemsModel>

/// What the Library screen decides, kept out of the views so app tests cover it.
enum LibraryPresentation {
    /// The messages of a library of `mediaType`; a podcast library says it has no podcasts.
    static func messages(for mediaType: MediaType?) -> BrowseMessages {
        BrowseMessages(
            failed: "MessageLibraryItemsLoadFailed",
            empty: mediaType == .podcast ? "MessageNoPodcastsFound" : "MessageNoItemsFound",
            systemImage: "books.vertical")
    }

    /// The bookshelf of the key's library and account, of type `mediaType`, with the account's saved preferences for
    /// it. A preference the user changes is saved for the account the model was built for, never another one.
    @MainActor
    static func makeModel(
        key: BrowseModelKey, mediaType: MediaType, services: LibraryStoreServices, store: LibraryStore
    ) -> LibraryItemsModel {
        let connection = key.connection
        return LibraryItemsModel(
            client: services, libraryID: key.libraryID, mediaType: mediaType,
            stored: store.viewPreferences(libraryID: key.libraryID), connectionKey: connection,
            persist: { [weak store] libraryID, preferences in
                store?.saveViewPreferences(preferences, libraryID: libraryID, connectionKey: connection)
            },
            map: { ItemSummary(item: $0) })
    }

    /// The host the screen's task keeps: `host` when built for `key` and `mediaType` (keeping what it loaded), else a
    /// new one. Until the library's type is known (its list hasn't loaded) there is no new model, as the type decides
    /// the sorts, filters and query; `host` stays only if it was built for `key`.
    @MainActor
    static func updated(
        _ host: LibraryModelHost?, for key: BrowseModelKey?, mediaType: MediaType?, store: LibraryStore?
    ) -> LibraryModelHost? {
        guard let key, let store else { return nil }
        guard let mediaType else { return host?.key == key ? host : nil }
        if let host, host.key == key, host.model.mediaType == mediaType { return host }
        return LibraryModelHost(key: key, store: store) { services in
            makeModel(key: key, mediaType: mediaType, services: services, store: store)
        }
    }

    /// The screen's state for its model.
    @MainActor
    static func state(of model: LibraryItemsModel) -> BrowseScreenState {
        .resolve(list: model.list)
    }

    /// The item count in the title area ("12 books", "1 podcast"); `nil` until a page told the total.
    static func countText(total: Int?, mediaType: MediaType, locale: Locale? = nil) -> String? {
        guard let total else { return nil }
        let isPodcast = mediaType == .podcast
        let key =
            switch (isPodcast, total == 1) {
            case (false, false): "LabelLibraryBookCount"
            case (false, true): "LabelLibraryBookCountOne"
            case (true, false): "LabelLibraryPodcastCount"
            case (true, true): "LabelLibraryPodcastCountOne"
            }
        return L10n.string(key, total.formatted(.number.locale(locale ?? .current)), locale: locale)
    }
}
