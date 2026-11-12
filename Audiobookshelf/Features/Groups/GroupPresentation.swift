import ABSAppModel
import ABSCore
import ABSUI
import Foundation

/// A library's collections or the user's playlists in it, a page at a time.
typealias GroupListModel = ItemListModel<String, GroupSummary>

/// A group the detail screens show: ``GroupDetailKind`` with the list kind it belongs to, so a screen's messages and
/// routes always match the group it loads.
protocol GroupScreenKind: GroupDetailKind {
    static var summaryKind: GroupSummary.Kind { get }
}

extension CollectionGroupKind: GroupScreenKind {
    static var summaryKind: GroupSummary.Kind { .collection }
}

extension PlaylistGroupKind: GroupScreenKind {
    static var summaryKind: GroupSummary.Kind { .playlist }
}

/// What play-all offers on a collection or playlist: legacy shows Play while any member is playable, and plays the
/// first playable member that isn't finished.
struct GroupPlayAll: Hashable {
    /// The member Play starts; `nil` when every playable member is finished. Legacy's Play then does nothing; here
    /// it is disabled and its hint says why (``hintKey``).
    let next: GroupMember?
    /// There is a member to play and a player to play it.
    let isEnabled: Bool

    /// The hint of a Play disabled because every playable member is finished.
    var hintKey: String? { next == nil ? "MessageGroupAllFinished" : nil }
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

    /// The model's group if it belongs to the library `libraryID`. A deep link can name another library's group,
    /// which is shown as not found: legacy leaves a group's page when the library changes (`libraryChanged()`).
    @MainActor
    static func detail<Kind>(of model: GroupDetailModel<Kind>, libraryID: String) -> GroupDetail? {
        model.detail.flatMap { $0.libraryID == libraryID ? $0 : nil }
    }

    /// The detail screen's state in the library `libraryID`; loaded is never empty, as the header shows and a group
    /// without members says so.
    @MainActor
    static func state<Kind>(of model: GroupDetailModel<Kind>, libraryID: String) -> BrowseScreenState {
        let isElsewhere = model.detail != nil && detail(of: model, libraryID: libraryID) == nil
        return .resolve(
            .init(
                hasLoaded: model.hasLoaded, hasContent: true, isLoading: model.isLoading,
                hasError: model.error != nil, isNotFound: model.isNotFound || isElsewhere))
    }

    /// "1 item" or "3 items". The catalog has no plural variations, so one is its own key.
    ///
    /// A list card counts the server's entries, so a member listed twice counts twice; the detail screen shows it
    /// once (``GroupDetail/members``).
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
    /// Legacy plays only that member, and Play becomes Pause while one of the group's members plays.
    /// TODO(#354): queue the playable members after it, and show Pause, once the app has a `PlaybackQueue` and the
    /// player's state.
    ///
    /// - Returns: The failure message's key; `nil` when it started, was cancelled or had nothing to play.
    @MainActor
    static func performPlayAll(_ playAll: GroupPlayAll, play: PlayItemAction?) async -> String? {
        guard playAll.isEnabled, let next = playAll.next else { return nil }
        return await ItemCardActions.perform(.play, on: next.summary, actions: NoOpItemActions(), play: play)
    }
}
