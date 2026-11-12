import ABSAppModel
import ABSCore
import SwiftUI

/// What the book screen's More menu shows for each ``ItemDetailMenuAction`` and how it performs
/// the progress actions. Built apart from the view so the rules can be tested.
enum ItemDetailMenuPresentation {
    /// The entries to offer, and to recheck when a confirmed action runs: the model's
    /// ``ItemDetailModel/menuActions(canEditPlaylists:canShare:isGone:)``, without History when
    /// there is no router to push it on (previews). `isGone` is the screen's
    /// ``ItemDetailGoneState``, so a retry that fails after a 404 doesn't bring the progress
    /// actions back for a deleted item.
    @MainActor
    static func actions(
        for model: ItemDetailModel, isGone: Bool, canEditPlaylists: Bool, canShare: Bool, canRoute: Bool
    ) -> [ItemDetailMenuAction] {
        model.menuActions(canEditPlaylists: canEditPlaylists, canShare: canShare, isGone: isGone)
            .filter { $0 != .history || canRoute }
    }

    /// The key of the entry's title (legacy `ItemMoreMenuModal.vue` wording).
    static func titleKey(for action: ItemDetailMenuAction) -> String {
        switch action {
        case .markFinished: "MessageMarkAsFinished"
        case .markNotFinished: "SharedMarkAsNotFinished"
        case .discardProgress: "MessageDiscardProgress"
        case .hideFromContinueListening: "SharedHideFromContinueListening"
        case .addToPlaylist: "LabelAddToPlaylist"
        case .share: "ButtonShare"
        case .details: "LabelMoreInfo"
        case .history: "ButtonHistory"
        }
    }

    /// The entry's SF Symbol; the card actions' symbols where they overlap.
    static func systemImage(for action: ItemDetailMenuAction) -> String {
        switch action {
        case .markFinished: "checkmark.circle"
        case .markNotFinished: "arrow.uturn.backward.circle"
        case .discardProgress: "delete.backward"
        case .hideFromContinueListening: "eye.slash"
        case .addToPlaylist: "text.badge.plus"
        case .share: "square.and.arrow.up"
        case .details: "info.circle"
        case .history: "clock.arrow.circlepath"
        }
    }

    /// Discarding progress can't be undone, so its entry and confirm button are destructive.
    static func role(for action: ItemDetailMenuAction) -> ButtonRole? {
        action == .discardProgress ? .destructive : nil
    }

    /// Performs a progress action on the book: marking and hiding as the item cards do
    /// (``ItemCardActions``), discarding through ``ItemActionPerforming/discardProgress(_:)``.
    /// Share, More info, History and Add to playlist are the view's.
    ///
    /// - Returns: The failure message's key; `nil` when the action succeeded, was cancelled or
    ///   isn't performed here.
    @MainActor
    static func perform(
        _ action: ItemDetailMenuAction, on summary: ItemSummary, actions: any ItemActionPerforming
    ) async -> String? {
        switch action {
        case .markFinished:
            return await ItemCardActions.perform(.markFinished, on: summary, actions: actions, play: nil)
        case .markNotFinished:
            return await ItemCardActions.perform(.markNotFinished, on: summary, actions: actions, play: nil)
        case .hideFromContinueListening:
            return await ItemCardActions.perform(.hideFromContinueListening, on: summary, actions: actions, play: nil)
        case .discardProgress:
            let target = ItemActionTarget(
                libraryItemID: summary.itemID, episodeID: summary.episodeID, duration: summary.duration)
            do {
                try await actions.discardProgress(target)
                return nil
            } catch is CancellationError {
                return nil
            } catch {
                return "MessageItemDetailDiscardProgressFailed"
            }
        case .addToPlaylist, .share, .details, .history:
            return nil
        }
    }
}
