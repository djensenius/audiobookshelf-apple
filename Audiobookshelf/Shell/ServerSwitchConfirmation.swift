import ABSAppModel
import ABSCore
import ABSData
import ABSUI
import SwiftUI

/// Hands a link back to the root (`RootView`) after a confirmed server switch. The root counts
/// the links it receives, so a link that arrived while the switch ran wins over the one handed
/// back: the root keeps one link, the last received.
@MainActor
struct LinkReopener {
    /// How many links the root has received.
    var receivedLinks: @MainActor () -> Int = { 0 }
    var receive: @MainActor (DeepLink) -> Void = { _ in }

    /// Notes the links received so far; the returned closure hands its link to the root only if
    /// none arrived since.
    func reopenUnlessSuperseded() -> @MainActor (DeepLink) -> Void {
        let received = receivedLinks()
        return { [self] link in
            guard receivedLinks() == received else {
                Log.ui.notice("Dropped a link a newer link replaced during a server switch")
                return
            }
            receive(link)
        }
    }
}

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
    /// runs the dialog's action and its dismissal in. The switch runs in its own task
    /// (``AccountActions/switchAccount(to:)``), so the old host going away doesn't cancel it; a
    /// failed switch drops the link, as does a newer link arriving meanwhile.
    /// - Returns: A task whose value is whether the switch succeeded, or `nil` when the server is
    ///   unknown or the session isn't ready (then nothing changes).
    @discardableResult
    func confirm(_ link: DeepLink, in router: Router, reopen: LinkReopener) -> Task<Bool, Never>? {
        guard lifecycle.acceptsAccountChanges else { return nil }
        if router.pendingServerSwitch == link { router.pendingServerSwitch = nil }
        guard let connection = connection(for: link) else {
            Log.ui.notice("Dropped a link for a server that isn't saved")
            return nil
        }
        guard let switching = AccountActions(lifecycle: lifecycle).switchAccount(to: connection.id) else { return nil }
        let reopen = reopen.reopenUnlessSuperseded()
        return Task {
            let switched = await switching.value
            if switched { reopen(link) }
            return switched
        }
    }
}

/// Asks before opening a link for another saved server. Needs the lifecycle and the accounts in
/// the environment (`RootView` puts them there).
struct ServerSwitchConfirmationModifier: ViewModifier {
    let router: Router
    let reopen: LinkReopener
    @Environment(SessionLifecycle.self) private var lifecycle: SessionLifecycle?
    @Environment(AccountManager.self) private var accounts: AccountManager?
    @State private var switchFailed = false

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
                        let switching = confirmation.confirm(target.link, in: router, reopen: reopen)
                        Task {
                            if let switching, await !switching.value { switchFailed = true }
                        }
                    } label: {
                        Text(verbatim: L10n.string("ButtonSwitchServer"))
                    }
                    .disabled(!lifecycle.acceptsAccountChanges)
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
                .switchServerFailedAlert(isPresented: $switchFailed)
        } else {
            content
        }
    }
}

extension View {
    /// Tells the user a server switch failed. A failed switch leaves the account where it was, so
    /// the same shell, and this alert, stays on screen.
    func switchServerFailedAlert(isPresented: Binding<Bool>) -> some View {
        alert(Text(verbatim: L10n.string("MessageSwitchServerFailed")), isPresented: isPresented) {
            Button(role: .cancel) {
            } label: {
                Text(verbatim: L10n.string("ButtonOk"))
            }
        }
    }
}
