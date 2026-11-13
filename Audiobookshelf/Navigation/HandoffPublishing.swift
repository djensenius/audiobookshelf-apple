import ABSAppModel
import SwiftUI

/// Publishes the shown item or episode as a Handoff activity (ADR 0004, "Handoff"), so another
/// device signed in to the same account can continue it. The payload names the active account
/// by its server address and user ID, never by its local connection ID; with no active
/// connection, or IDs a receiver would reject, nothing is published.
struct HandoffPublishing: ViewModifier {
    let itemID: String
    let episodeID: String?
    @Environment(AccountManager.self) private var accounts: AccountManager?

    func body(content: Content) -> some View {
        let userInfo = accounts?.activeConnection.flatMap(HandoffAccount.init(connection:)).flatMap {
            DeepLink.handoffUserInfo(itemID: itemID, episodeID: episodeID, account: $0)
        }
        content.userActivity(DeepLink.handoffActivityType, isActive: userInfo != nil) { activity in
            activity.isEligibleForHandoff = true
            activity.userInfo = userInfo
        }
    }
}

extension View {
    /// Publishes this item or episode screen for Handoff (``HandoffPublishing``).
    func publishesHandoff(itemID: String, episodeID: String? = nil) -> some View {
        modifier(HandoffPublishing(itemID: itemID, episodeID: episodeID))
    }
}
