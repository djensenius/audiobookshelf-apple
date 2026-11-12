import ABSCore
import Foundation

/// Which item actions need the server, and why they're unavailable while it can't be reached
/// (#76): the views disable them and show ``reasonKey``, a localized key. Online, everything the
/// caller offers stays available.
///
/// - Progress changes, hiding from Continue Listening and playlists go through the server.
/// - Playing and opening an item work offline only when it's downloaded.
/// - Sharing (the item's web address), More info and the on-device History stay available.
public struct ServerActionAvailability: Sendable, Hashable {
    public var connection: ConnectionBannerState

    public init(connection: ConnectionBannerState) {
        self.connection = connection
    }

    /// Why server actions are unavailable: the connection's message key, or `nil` online.
    public var reasonKey: String? { connection.messageKey }

    /// Why a card or row action is unavailable, or `nil` when it can be performed.
    public func reasonKey(for kind: ItemActionKind, isDownloaded: Bool) -> String? {
        guard let reasonKey else { return nil }
        switch kind {
        case .play, .openDetails:
            return isDownloaded ? nil : reasonKey
        case .markFinished, .markNotFinished, .hideFromContinueListening, .addToPlaylist:
            return reasonKey
        case .share:
            return nil
        }
    }

    /// Why a More menu entry on the item screen is unavailable, or `nil` when it can be performed.
    public func reasonKey(for action: ItemDetailMenuAction) -> String? {
        guard let reasonKey else { return nil }
        switch action {
        case .markFinished, .markNotFinished, .discardProgress, .hideFromContinueListening, .addToPlaylist:
            return reasonKey
        case .share, .details, .history:
            return nil
        }
    }
}
