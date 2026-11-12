import ABSAppModel
import ABSCore
import ABSUI
import Foundation

/// A library's collections or the user's playlists in it, a page at a time.
typealias GroupListModel = ItemListModel<String, GroupSummary>

/// What play-all offers on a collection or playlist: legacy shows Play while any member is playable, and plays the
/// first playable member that isn't finished.
struct GroupPlayAll: Hashable {
    /// The member Play starts; `nil` when every playable member is finished, so Play does nothing.
    let next: GroupMember?
    /// There is a member to play and a player to play it.
    let isEnabled: Bool
}

/// What the collection and playlist screens decide, kept out of the views so app tests cover it.
enum GroupPresentation {
    static func listMessages(_ kind: GroupSummary.Kind) -> BrowseMessages {
        switch kind {
        case .collection:
            BrowseMessages(
                failed: "MessageCollectionsListLoadFailed", empty: "MessageNoCollections", systemImage: "square.stack")
        case .playlist:
            BrowseMessages(
                failed: "MessagePlaylistsListLoadFailed", empty: "MessageNoUserPlaylists",
                systemImage: "music.note.list")
        }
    }

    static func detailMessages(_ kind: GroupSummary.Kind) -> BrowseMessages {
        switch kind {
        case .collection:
            BrowseMessages(
                failed: "MessageCollectionDetailLoadFailed", empty: "MessageNoItems",
                notFound: "MessageCollectionDetailNotFound", systemImage: "square.stack")
        case .playlist:
            BrowseMessages(
                failed: "MessagePlaylistDetailLoadFailed", empty: "MessageNoItems",
                notFound: "MessagePlaylistDetailNotFound", systemImage: "music.note.list")
        }
    }

    /// The section a list is the root of.
    static func tab(_ kind: GroupSummary.Kind) -> AppTab {
        kind == .collection ? .collections : .playlists
    }

    /// The detail screen's title until the group has loaded.
    static func detailTitleKey(_ kind: GroupSummary.Kind) -> String {
        kind == .collection ? "HeaderCollection" : "HeaderPlaylist"
    }

    /// The heading above the members, as in legacy `CollectionBooksTable.vue` and `PlaylistItemsTable.vue`.
    static func membersHeaderKey(_ kind: GroupSummary.Kind) -> String {
        kind == .collection ? "HeaderCollectionItems" : "HeaderPlaylistItems"
    }

    /// The screen of the group `id`.
    static func route(_ kind: GroupSummary.Kind, id: String) -> Route {
        kind == .collection ? .collection(id: id) : .playlist(id: id)
    }

    /// The list of the key's library and account.
    @MainActor
    static func makeList(_ kind: GroupSummary.Kind, key: BrowseModelKey, services: LibraryStoreServices)
        -> GroupListModel
    {
        switch kind {
        case .collection: .collections(service: services, libraryID: key.libraryID, connectionKey: key.connection)
        case .playlist: .playlists(service: services, libraryID: key.libraryID, connectionKey: key.connection)
        }
    }

    /// The detail screen's state; loaded is never empty, as the header shows and a group without members says so.
    @MainActor
    static func state<Kind>(of model: GroupDetailModel<Kind>) -> BrowseScreenState {
        .resolve(
            .init(
                hasLoaded: model.hasLoaded, hasContent: true, isLoading: model.isLoading,
                hasError: model.error != nil, isNotFound: model.isNotFound))
    }

    /// "1 item" or "3 items". The catalog has no plural variations, so one is its own key.
    static func itemCount(_ count: Int, locale: Locale? = nil) -> String {
        count == 1
            ? L10n.string("LabelGroupOneItem", locale: locale)
            : L10n.string("LabelGroupItemCount", count.formatted(.number.locale(locale ?? .current)), locale: locale)
    }

    /// A list card as VoiceOver reads it: the name, then the item count.
    static func cardAccessibilityLabel(_ group: GroupSummary, locale: Locale? = nil) -> String {
        [group.name, itemCount(group.itemCount, locale: locale)].joined(separator: ", ")
    }

    /// Play-all for the model's group; `nil` (no button) until it has loaded or when no member is playable.
    @MainActor
    static func playAll<Kind>(of model: GroupDetailModel<Kind>, canPlay: Bool) -> GroupPlayAll? {
        guard let members = model.detail?.members, !model.playTargets.isEmpty else { return nil }
        let next = model.nextToPlay.flatMap { target in members.first { $0.target == target } }
        return GroupPlayAll(next: next, isEnabled: canPlay && next != nil)
    }

    /// Play as VoiceOver reads it: the action, then what it plays.
    static func playAllAccessibilityLabel(_ playAll: GroupPlayAll) -> String {
        [L10n.string("ButtonPlay"), playAll.next?.summary.title].compactMap(\.self).joined(separator: ", ")
    }

    /// Plays the member play-all starts through `play`, like a card's Play.
    ///
    /// Legacy plays only that member. TODO(#156): queue the playable members after it once the app shell has a
    /// `PlaybackQueue` to add them to.
    ///
    /// - Returns: The failure message's key; `nil` when it started, was cancelled or had nothing to play.
    @MainActor
    static func performPlayAll(_ playAll: GroupPlayAll, play: PlayItemAction?) async -> String? {
        guard playAll.isEnabled, let next = playAll.next else { return nil }
        return await ItemCardActions.perform(.play, on: next.summary, actions: NoOpItemActions(), play: play)
    }
}
