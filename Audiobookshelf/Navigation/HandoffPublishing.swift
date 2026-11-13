import ABSAppModel
import ABSData
import SwiftUI

/// Publishes the shown item or episode as a Handoff activity (ADR 0004, "Handoff"), so another
/// device signed in to the same account can continue it. The payload names the active account
/// by its server address and user ID, never by its local connection ID; with no active
/// connection, IDs a receiver would reject, or a shell that isn't the active account's,
/// nothing is published. Only the screen on top of the selected tab's stack publishes
/// (``isFrontmost(itemID:episodeID:in:owner:)``).
struct HandoffPublishing: ViewModifier {
    let itemID: String
    let episodeID: String?
    @Environment(AccountManager.self) private var accounts: AccountManager?
    @Environment(SessionLifecycle.self) private var lifecycle: SessionLifecycle?
    @Environment(Router.self) private var router: Router?
    @Environment(\.navigationTab) private var owner

    func body(content: Content) -> some View {
        let isFrontmost = Self.isFrontmost(itemID: itemID, episodeID: episodeID, in: router, owner: owner)
        let account = lifecycle.flatMap {
            Self.account(active: accounts?.activeConnection, shown: SceneContent($0.gate))
        }
        let userInfo = account.flatMap { isFrontmost ? $0 : nil }.flatMap {
            DeepLink.handoffUserInfo(itemID: itemID, episodeID: episodeID, account: $0)
        }
        content.userActivity(DeepLink.handoffActivityType, isActive: userInfo != nil) { activity in
            activity.isEligibleForHandoff = true
            activity.userInfo = userInfo
        }
    }

    /// Whether this item or episode screen tops the selected tab's stack, as for ⌘R
    /// (``RefreshCommandPlacement/isFrontmost(in:owner:isVisible:)``). macOS keeps a hidden tab's
    /// screens appeared, and a covered screen stays in its stack, so neither publishes. Without
    /// a router (previews), it does.
    @MainActor
    static func isFrontmost(itemID: String, episodeID: String?, in router: Router?, owner: AppTab?) -> Bool {
        let route = episodeID.map { Route.episode(itemID: itemID, episodeID: $0) } ?? .item(id: itemID)
        return RefreshCommandPlacement.pushed(route).isFrontmost(in: router, owner: owner, isVisible: true)
    }

    /// The account to name in the activity: the active connection's, only while it is the
    /// account of the shell on screen (as ``RootView/statsService(_:for:)`` checks). During a
    /// switch the outgoing shell stays up after `activeConnection` moved to the next account,
    /// and its item and episode IDs belong to the outgoing one, so it publishes nothing.
    static func account(active: ServerConnectionDTO?, shown: SceneContent) -> HandoffAccount? {
        guard case .shell(let identity, _) = shown, let active,
            active.id == identity.connectionID, active.userId == identity.userID
        else { return nil }
        return HandoffAccount(connection: active)
    }
}

extension View {
    /// Publishes this item or episode screen for Handoff (``HandoffPublishing``).
    func publishesHandoff(itemID: String, episodeID: String? = nil) -> some View {
        modifier(HandoffPublishing(itemID: itemID, episodeID: episodeID))
    }
}
