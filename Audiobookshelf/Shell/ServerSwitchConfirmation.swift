import ABSAppModel
import ABSCore
import ABSData
import ABSUI
import SwiftUI

/// The links a scene has received, as `RootView` keeps them: one waits at a time, the last
/// received. Once the user confirms a switch to another server, links wait in a slot instead,
/// starting with the confirmed one, and any newer link replaces it, including one that arrives
/// before the switch has changed the gate (which the outgoing account's epoch would drop). When
/// the switch has finished, the slot's link waits with the new account's
/// ``SessionLifecycle/linkEpoch``. A failed switch drops the confirmed link, but a newer one
/// waits as if it had just arrived (a link for another server asks again).
struct SceneLinks {
    private(set) var pending: PendingLink?
    /// The link to open after the confirmed switch, while it runs.
    private(set) var afterSwitch: DeepLink?
    private(set) var isSwitching = false
    /// Whether a newer link replaced the confirmed one in ``afterSwitch``.
    private var replacedConfirmed = false

    mutating func receive(_ link: DeepLink, gate: AuthGate, epoch: UInt64) {
        if isSwitching {
            afterSwitch = link
            replacedConfirmed = true
        } else {
            pending = PendingLink(link, arrivingAt: gate, epoch: epoch)
        }
    }

    /// Keeps `link`, the confirmed one, until ``finishSwitch(succeeded:gate:epoch:)``. A link
    /// already waiting is older, so it goes.
    mutating func beginSwitch(with link: DeepLink) {
        isSwitching = true
        afterSwitch = link
        replacedConfirmed = false
        pending = nil
    }

    mutating func finishSwitch(succeeded: Bool, gate: AuthGate, epoch: UInt64) {
        guard isSwitching else { return }
        isSwitching = false
        defer { afterSwitch = nil }
        guard let link = afterSwitch else { return }
        if succeeded || replacedConfirmed {
            pending = PendingLink(link, arrivingAt: gate, epoch: epoch)
        } else {
            Log.ui.notice("Dropped a link: the server switch failed")
        }
    }

    func link(atEpoch epoch: UInt64) -> DeepLink? {
        pending?.link(atEpoch: epoch)
    }

    /// Drops a waiting link that arrived before `epoch`.
    mutating func dropStale(atEpoch epoch: UInt64) {
        if link(atEpoch: epoch) == nil { pending = nil }
    }

    mutating func clearPending() {
        pending = nil
    }
}

/// How a confirmed server switch hands its link to the root (`RootView`, ``SceneLinks``), which
/// outlives the scene's host that the switch rebuilds.
@MainActor
struct LinkReopener {
    var beginSwitch: @MainActor (DeepLink) -> Void = { _ in }
    var finishSwitch: @MainActor (_ succeeded: Bool) -> Void = { _ in }
}

/// The link the confirmation dialog asks about, for a saved server with a session.
struct ServerSwitchRequest {
    let link: DeepLink
    let connection: ServerConnectionDTO
    fileprivate let generation: Int
}

/// What the dialog shows. Each link presented gets a new generation, so the dialog's actions for
/// one a newer link replaced do nothing. Dismissing keeps the generation: SwiftUI may dismiss the
/// dialog before it runs the confirm action, which must still work.
struct ServerSwitchPrompt {
    private(set) var shown: ServerSwitchRequest?
    private var generation = 0

    mutating func present(_ link: DeepLink, for connection: ServerConnectionDTO) {
        generation += 1
        shown = ServerSwitchRequest(link: link, connection: connection, generation: generation)
    }

    mutating func dismiss(_ request: ServerSwitchRequest) {
        if request.generation == generation { shown = nil }
    }

    /// Takes `request` to confirm, once: `false` when a newer one was presented since, or it was
    /// taken already.
    mutating func take(_ request: ServerSwitchRequest) -> Bool {
        guard request.generation == generation else { return false }
        generation += 1
        shown = nil
        return true
    }
}

/// What the scene does with a link for another saved server (``Router/pendingServerSwitch``):
/// drop it when the server isn't saved or has no session, or ask, then switch to it and open the
/// link once confirmed.
///
/// The switch goes through ``SessionLifecycle/switchAccount(to:)``, so the current session
/// flushes and ends first. It rebuilds the scene's host (`.id(identity)` in `RootView`), so the
/// link is kept by the root (``LinkReopener``), not the old host, and opens there after the
/// switch, with the new account's ``SessionLifecycle/linkEpoch``.
@MainActor
struct ServerSwitchConfirmation {
    let lifecycle: SessionLifecycle
    let accounts: AccountManager?

    /// The saved connection `link` is for, or `nil` if it isn't saved, or is signed out.
    func connection(for link: DeepLink) -> ServerConnectionDTO? {
        guard let id = link.serverID.flatMap(UUID.init(uuidString:)) else { return nil }
        return accounts?.connections.first { $0.id == id && !$0.isDisconnected && $0.signedOutAt == nil }
    }

    /// Takes the router's pending link to ask about, clearing it. Returns the link and its
    /// connection, or `nil` after dropping a link whose server isn't saved or has no session to
    /// switch to (``AccountManager/hasSession(_:)``), or when a newer link replaced it meanwhile.
    func review(_ router: Router) async -> (link: DeepLink, connection: ServerConnectionDTO)? {
        guard let link = router.pendingServerSwitch else { return nil }
        var connection = connection(for: link)
        if let id = connection?.id, let accounts, await !accounts.hasSession(id) { connection = nil }
        guard router.pendingServerSwitch == link else { return nil }
        router.pendingServerSwitch = nil
        guard let connection else {
            Log.ui.notice("Dropped a link for a server that isn't saved or is signed out")
            return nil
        }
        return (link, connection)
    }

    /// Switches to the server of `request`, if it's still the one the prompt shows (or showed,
    /// if SwiftUI dismissed the dialog first), and hands its link to the root, which opens it, or
    /// a newer one, after the switch. The switch runs in its own task
    /// (``AccountActions/switchAccount(to:)``), so the old host going away doesn't cancel it.
    /// - Returns: A task whose value is whether the switch succeeded, or `nil` when the request
    ///   was replaced, or the session isn't ready (then nothing changes).
    @discardableResult
    func confirm(
        _ request: ServerSwitchRequest, prompt: inout ServerSwitchPrompt, reopen: LinkReopener
    ) -> Task<Bool, Never>? {
        guard lifecycle.acceptsAccountChanges, prompt.take(request),
            let switching = AccountActions(lifecycle: lifecycle, accounts: accounts)
                .switchAccount(to: request.connection.id)
        else { return nil }
        reopen.beginSwitch(request.link)
        return Task {
            let switched = await switching.value
            reopen.finishSwitch(switched)
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
    @State private var prompt = ServerSwitchPrompt()
    @State private var switchFailed = false

    func body(content: Content) -> some View {
        if let lifecycle {
            let confirmation = ServerSwitchConfirmation(lifecycle: lifecycle, accounts: accounts)
            // The request this render shows, so a dismissal can't clear a newer one.
            let shown = prompt.shown
            content
                .task(id: router.pendingServerSwitch) {
                    if let target = await confirmation.review(router) {
                        prompt.present(target.link, for: target.connection)
                    }
                }
                .confirmationDialog(
                    Text(verbatim: L10n.string("HeaderOpenLinkOnAnotherServer")),
                    isPresented: Binding {
                        shown != nil
                    } set: {
                        if !$0, let shown { prompt.dismiss(shown) }
                    },
                    titleVisibility: .visible,
                    presenting: shown
                ) { request in
                    Button {
                        let switching = confirmation.confirm(request, prompt: &prompt, reopen: reopen)
                        Task {
                            if let switching, await !switching.value { switchFailed = true }
                        }
                    } label: {
                        Text(verbatim: L10n.string("ButtonSwitchServer"))
                    }
                    .disabled(!lifecycle.acceptsAccountChanges)
                    Button(role: .cancel) {
                        prompt.dismiss(request)
                    } label: {
                        Text(verbatim: L10n.string("ButtonCancel"))
                    }
                } message: { request in
                    Text(
                        verbatim: L10n.string(
                            "MessageSwitchServerForLink", request.connection.username, request.connection.address))
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
