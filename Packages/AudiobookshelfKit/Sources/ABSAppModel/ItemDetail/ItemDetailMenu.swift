import ABSAPI
import ABSCore
import Foundation

/// An entry of the book screen's More menu (legacy `ItemMoreMenuModal.vue`). The order is the
/// menu order.
public enum ItemDetailMenuAction: Sendable, Hashable, CaseIterable {
    case markFinished
    case markNotFinished
    case discardProgress
    case hideFromContinueListening
    case addToPlaylist
    case share
    case details
    case history
}

extension ItemDetailModel {
    /// The More menu's entries for the loaded book and the user's progress, in menu order.
    ///
    /// - Nothing until a book has loaded (podcasts have their own screen).
    /// - A book missing or invalid on the server, or gone (the last load answered 404), offers
    ///   only Share, More info and History: its progress and playlists can't change.
    /// - Mark as finished, or Mark as not finished once finished.
    /// - Discard progress with any progress above 0, ebook progress included (legacy
    ///   `progressPercent > 0`).
    /// - Hide from Continue Listening while in progress and not hidden, as on cards
    ///   (`ItemAction.available`).
    /// - Add to playlist and Share only when the caller can perform them.
    public func menuActions(canEditPlaylists: Bool, canShare: Bool) -> [ItemDetailMenuAction] {
        guard let item, item.book != nil else { return [] }
        // TODO(#345): share the gone check with the app's `ItemDetailGoneState` once slice A lands.
        let present = !item.isMissing && !item.isInvalid && (error as? APIError) != .notFound
        var actions: [ItemDetailMenuAction] = []
        if present {
            actions.append(isFinished ? .markNotFinished : .markFinished)
            if progressFraction > 0 { actions.append(.discardProgress) }
            if let progress {
                let shown = ItemProgress(progress)
                if shown.isInProgress, !shown.isHiddenFromContinue { actions.append(.hideFromContinueListening) }
            }
            if canEditPlaylists { actions.append(.addToPlaylist) }
        }
        if canShare { actions.append(.share) }
        actions.append(contentsOf: [.details, .history])
        return actions
    }

    /// The key of the question to ask before `action`, or `nil` to perform it straight away:
    /// marking finished asks when there is progress to overwrite (legacy `toggleFinished`), and
    /// discarding always asks.
    public func confirmationMessageKey(for action: ItemDetailMenuAction) -> String? {
        switch action {
        case .markFinished:
            !isFinished && progressFraction > 0 ? "MessageConfirmMarkAsFinished" : nil
        case .discardProgress:
            "MessageConfirmDiscardProgress"
        case .markNotFinished, .hideFromContinueListening, .addToPlaylist, .share, .details, .history:
            nil
        }
    }

    /// The web client's page for the item, `<server>/item/<id>`: under the server's base path
    /// (a server behind `/audiobookshelf`), with the ID as one percent-encoded path component.
    public static func webURL(serverURL: URL, itemID: String) -> URL {
        serverURL.appending(component: "item").appending(component: itemID)
    }
}
