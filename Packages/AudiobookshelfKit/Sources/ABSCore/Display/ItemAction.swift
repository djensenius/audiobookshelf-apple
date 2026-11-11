import Foundation

/// Something a user can do with an item from a card, row or menu. The order is the menu order.
public enum ItemActionKind: Sendable, Hashable, CaseIterable {
    case play
    case markFinished
    case markNotFinished
    case hideFromContinueListening
    case addToPlaylist
    case share
    case openDetails
}

/// One available action. Views turn it into a button and a VoiceOver action.
public struct ItemAction: Sendable, Hashable, Identifiable {
    public let kind: ItemActionKind

    public init(_ kind: ItemActionKind) {
        self.kind = kind
    }

    public var id: ItemActionKind { kind }
}

/// What the caller knows that the item doesn't.
public struct ItemActionContext: Sendable, Hashable {
    /// Whether adding to a playlist is wired up and allowed for this user.
    public var canEditPlaylists: Bool
    /// Whether playing is wired up, for example while the screen has no player to call.
    public var canPlay: Bool
    /// Whether sharing is wired up on this screen.
    public var canShare: Bool

    public init(canEditPlaylists: Bool = false, canPlay: Bool = true, canShare: Bool = true) {
        self.canEditPlaylists = canEditPlaylists
        self.canPlay = canPlay
        self.canShare = canShare
    }
}

extension ItemAction {
    /// The actions available for `item` given the user's `progress` on it, in menu order.
    ///
    /// - Books and episodes can be played, marked and hidden; a podcast or a collapsed series
    ///   only opens (playing is per episode, finishing per book).
    /// - A missing or invalid item or one without audio can't be played; a missing item can't be
    ///   changed or added to a playlist either, but can still be opened.
    /// - Hiding applies to items in progress that are not hidden already.
    /// - Play and share are left out when the context says the screen can't perform them.
    public static func available(
        for item: ItemSummary, progress: ItemProgress?, context: ItemActionContext = ItemActionContext()
    ) -> [ItemAction] {
        let playable = item.kind == .book || item.kind == .episode
        let present = !item.isMissing
        let finished = progress?.isFinished ?? false
        var kinds: [ItemActionKind] = []
        if playable, present, item.hasAudio, context.canPlay { kinds.append(.play) }
        if playable, present { kinds.append(finished ? .markNotFinished : .markFinished) }
        if playable, present, let progress, progress.isInProgress, !progress.isHiddenFromContinue {
            kinds.append(.hideFromContinueListening)
        }
        if playable, present, context.canEditPlaylists { kinds.append(.addToPlaylist) }
        if item.kind != .series, present, context.canShare { kinds.append(.share) }
        kinds.append(.openDetails)
        return kinds.map(ItemAction.init)
    }
}
