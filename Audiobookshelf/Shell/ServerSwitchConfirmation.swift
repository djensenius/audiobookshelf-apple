import ABSAppModel
import ABSCore
import ABSData
import ABSUI
import SwiftUI

/// What the scene does with a link for another saved server (``Router/pendingServerSwitch``):
/// drop it when the server isn't saved, or switch to it and reopen the link once confirmed.
///
/// The switch goes through ``SessionLifecycle/switchAccount(to:)``, so the current session
/// flushes and ends first. It rebuilds the scene's host (`.id(identity)` in `RootView`), so the
/// link is kept here, not in the old host, and handed back to the root after the switch, where
/// it carries the new account's ``SessionLifecycle/linkEpoch``.
@MainActor
struct ServerSwitchConfirmation {
    let lifecycle: SessionLifecycle
    let accounts: AccountManager?

    /// The saved connection `link` is for, or `nil` if it isn't saved, or is signed out, so
    /// there's no session to switch to.
    func connection(for link: DeepLink) -> ServerConnectionDTO? {
        guard let id = link.serverID.flatMap(UUID.init(uuidString:)) else { return nil }
        return accounts?.connections.first { $0.id == id && !$0.isDisconnected && $0.signedOutAt == nil }
    }

    /// Clears a pending link whose server can't be switched to, so nothing asks about it.
    func dropIfUnknown(_ router: Router) {
        guard let link = router.pendingServerSwitch, connection(for: link) == nil else { return }
        router.pendingServerSwitch = nil
        Log.ui.notice("Dropped a link for a server that isn't saved")
    }

    func cancel(_ router: Router) {
        router.pendingServerSwitch = nil
    }

    /// Switches to the server of `link`, the pending link the user confirmed, then hands the
    /// link to `reopen`. The link is cleared from the router first, whichever order SwiftUI
    /// runs the dialog's action and its dismissal in. The switch runs in its own task, so the
    /// old host going away doesn't cancel it; a failed switch is logged and drops the link.
    /// - Returns: The switch's task, or `nil` when the server is unknown.
    @discardableResult
    func confirm(
        _ link: DeepLink, in router: Router, reopen: @escaping @MainActor (DeepLink) -> Void
    ) -> Task<Void, Never>? {
        if router.pendingServerSwitch == link { router.pendingServerSwitch = nil }
        guard let connection = connection(for: link) else {
            Log.ui.notice("Dropped a link for a server that isn't saved")
            return nil
        }
        return Task { [lifecycle] in
            do {
                try await lifecycle.switchAccount(to: connection.id)
                reopen(link)
            } catch {
                Log.ui.error(
                    "Couldn't switch servers for a link: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }
}

/// Asks before opening a link for another saved server. Needs the lifecycle and the accounts in
/// the environment (`RootView` puts them there).
struct ServerSwitchConfirmationModifier: ViewModifier {
    let router: Router
    let reopen: @MainActor (DeepLink) -> Void
    @Environment(SessionLifecycle.self) private var lifecycle: SessionLifecycle?
    @Environment(AccountManager.self) private var accounts: AccountManager?

    func body(content: Content) -> some View {
        if let lifecycle {
            let confirmation = ServerSwitchConfirmation(lifecycle: lifecycle, accounts: accounts)
            let target = router.pendingServerSwitch.flatMap { link in
                confirmation.connection(for: link).map { (link: link, connection: $0) }
            }
            content
                .onChange(of: router.pendingServerSwitch, initial: true) { confirmation.dropIfUnknown(router) }
                .confirmationDialog(
                    Text(verbatim: L10n.string("HeaderOpenLinkOnAnotherServer")),
                    isPresented: Binding {
                        target != nil
                    } set: {
                        if !$0 { confirmation.cancel(router) }
                    },
                    titleVisibility: .visible,
                    presenting: target
                ) { target in
                    Button {
                        confirmation.confirm(target.link, in: router, reopen: reopen)
                    } label: {
                        Text(verbatim: L10n.string("ButtonSwitchServer"))
                    }
                    Button(role: .cancel) {
                        confirmation.cancel(router)
                    } label: {
                        Text(verbatim: L10n.string("ButtonCancel"))
                    }
                } message: { target in
                    Text(
                        verbatim: L10n.string(
                            "MessageSwitchServerForLink", target.connection.username, target.connection.address))
                }
        } else {
            content
        }
    }
}
