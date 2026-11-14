import ABSAppModel
import ABSData
import SwiftUI

/// Publishes the shown item or episode as a Handoff activity (ADR 0004, "Handoff"), so another
/// device signed in to the same account can continue it. The payload names the active account
/// by its server address and user ID, never by its local connection ID; with no active
/// connection, IDs a receiver would reject, or a shell that isn't the active account's,
/// nothing is published. Only the screen on top of the selected tab's stack publishes
/// (``isFrontmost(itemID:episodeID:in:owner:)``), and none while the full player covers it, which
/// publishes instead (``PlayerHandoffPublishing``).
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
    /// screens appeared, and a covered screen stays in its stack, so neither publishes. Nor does
    /// one under the full player (iOS's cover), which publishes the playing item instead; on macOS
    /// the flag resets as the Now Playing window opens, and each window publishes its own. Without
    /// a router (previews), it does.
    @MainActor
    static func isFrontmost(itemID: String, episodeID: String?, in router: Router?, owner: AppTab?) -> Bool {
        if router?.isFullPlayerPresented == true { return false }
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

/// Publishes what the full player plays, a book or a podcast episode, as a Handoff activity with
/// its position (ADR 0004, "Handoff"), so another device can continue it from there: the receiver
/// asks before it plays. The player is the top screen while it's shown, the cover on iOS (where
/// ``HandoffPublishing`` stands down meanwhile) or the Now Playing window on macOS, and stops
/// publishing when it closes.
///
/// The account is the active connection's, only while the playing media is on it
/// (``DeepLink/handoffUserInfo(playing:position:active:)``).
///
/// The position changes on every playback tick, so the body doesn't read it: the activity's
/// update reads it when SwiftUI saves the activity. The body changes, marking the activity for
/// saving again, when the item, the account or play/pause change, and every
/// ``refreshInterval`` while the player is shown, so a seek or playback is reflected within that.
struct PlayerHandoffPublishing: ViewModifier {
    let model: PlayerViewModel
    @Environment(AccountManager.self) private var accounts: AccountManager?
    /// Advanced every ``refreshInterval``, so the activity's position is saved again.
    @State private var refresh = 0

    static let refreshInterval: Duration = .seconds(15)

    func body(content: Content) -> some View {
        let active = accounts?.activeConnection
        // The item and account, without the position, which only the update reads.
        let base = model.mediaKey.flatMap { DeepLink.handoffUserInfo(playing: $0, position: nil, active: active) }
        // Read so pausing, resuming and the refresh tick update the activity.
        let generation = (refresh, model.showsPause)
        content
            .userActivity(DeepLink.handoffActivityType, isActive: base != nil) { activity in
                _ = generation
                activity.isEligibleForHandoff = true
                activity.userInfo = model.handoffUserInfo(active: active) ?? base
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.refreshInterval)
                    refresh &+= 1
                }
            }
    }
}

extension View {
    /// Publishes this item or episode screen for Handoff (``HandoffPublishing``).
    func publishesHandoff(itemID: String, episodeID: String? = nil) -> some View {
        modifier(HandoffPublishing(itemID: itemID, episodeID: episodeID))
    }

    /// Publishes what the full player plays for Handoff (``PlayerHandoffPublishing``).
    func publishesPlayerHandoff(_ model: PlayerViewModel) -> some View {
        modifier(PlayerHandoffPublishing(model: model))
    }
}
