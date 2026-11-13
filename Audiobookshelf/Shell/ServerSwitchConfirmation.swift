import ABSAppModel
import ABSCore
import ABSData
import ABSUI
import SwiftUI

/// The links a scene received (`RootView`): the last waits. During a confirmed switch, the last
/// since confirming waits for the new ``SessionLifecycle/linkEpoch``; a failure drops only it.
struct SceneLinks {
    private(set) var pending: PendingLink?
    /// The link to open after the confirmed switch, while it runs.
    private(set) var afterSwitch: DeepLink?
    private(set) var isSwitching = false
    /// Whether a newer link replaced the confirmed one in ``afterSwitch``.
    private var replacedConfirmed = false
    /// Counts the links received, so one resolved after it arrived (Handoff) doesn't replace a
    /// link received while it resolved.
    private var arrivals: UInt64 = 0
    /// Counts the continued Handoff activities received. At each, the host drops the server
    /// switch it asks about (``ServerSwitchPrompt/supersede(in:)``), whatever the activity
    /// resolves to.
    private(set) var handoffArrivals: UInt64 = 0

    mutating func receive(_ link: DeepLink, gate: AuthGate, epoch: UInt64) {
        arrivals &+= 1
        keep(link, gate: gate, epoch: epoch)
    }

    /// Takes the next arrival for a continued Handoff activity, before its account is resolved
    /// (``receive(_:gate:epoch:arrival:currentEpoch:)``). The activity is the newest link even if
    /// it opens nothing, so the waiting link and a confirmed switch's link go now.
    mutating func reserveArrival() -> UInt64 {
        arrivals &+= 1
        handoffArrivals &+= 1
        pending = nil
        afterSwitch = nil
        return arrivals
    }

    /// A continued Handoff activity's resolution, with the gate, epoch and arrival from when it
    /// arrived. Its link waits like any other. An activity whose account isn't signed in here
    /// opens nothing, on no account. Either result is stale, and does nothing, when a link arrived
    /// while it resolved (the last received wins) or the session changed (`currentEpoch`, the
    /// lifecycle's now, isn't `epoch`).
    /// - Returns: That account, for the scene to say it isn't signed in on this device.
    mutating func receive(
        _ resolution: HandoffResolution, gate: AuthGate, epoch: UInt64, arrival: UInt64, currentEpoch: UInt64
    ) -> HandoffAccount? {
        guard arrival == arrivals, epoch == currentEpoch else {
            Log.ui.notice("Dropped a Handoff activity: a newer link arrived, or the session changed, while it resolved")
            return nil
        }
        switch resolution {
        case .open(let link):
            keep(link, gate: gate, epoch: epoch)
            return nil
        case .accountNotSignedIn(let account):
            return account
        }
    }

    private mutating func keep(_ link: DeepLink, gate: AuthGate, epoch: UInt64) {
        if isSwitching {
            afterSwitch = link
            replacedConfirmed = true
        } else {
            pending = PendingLink(link, arrivingAt: gate, epoch: epoch)
        }
    }

    /// Keeps `link`, the confirmed one, until ``finishSwitch(_:gate:epoch:)``.
    /// - Returns: `false`, changing nothing, when a newer link waits for `epoch` (it wins); one
    ///   waiting for an older epoch goes.
    mutating func beginSwitch(with link: DeepLink, epoch: UInt64) -> Bool {
        guard self.link(atEpoch: epoch) == nil else { return false }
        isSwitching = true
        afterSwitch = link
        replacedConfirmed = false
        pending = nil
        return true
    }

    /// After a success, the link waits for the switch's epoch, so a later change drops it.
    mutating func finishSwitch(_ outcome: SwitchOutcome, gate: AuthGate, epoch: UInt64) {
        guard isSwitching else { return }
        isSwitching = false
        defer { afterSwitch = nil }
        guard let link = afterSwitch else { return }
        if case .switched(let switched) = outcome {
            pending = PendingLink(link, arrivingAt: gate, epoch: switched)
        } else if replacedConfirmed {
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

/// How a confirmed switch hands its link to the root, which outlives the host it rebuilds.
@MainActor
struct LinkReopener {
    /// Whether the root took the link; not when a newer one waits.
    var beginSwitch: @MainActor (DeepLink) -> Bool = { _ in true }
    var finishSwitch: @MainActor (SwitchOutcome) -> Void = { _ in }
}

/// The link the confirmation dialog asks about, for a saved server with a session.
struct ServerSwitchRequest {
    let link: DeepLink
    let connection: ServerConnectionDTO
    fileprivate let generation: Int
}

/// What the dialog shows. Each link opened or presented gets a new generation, so actions for a
/// replaced one do nothing; dismissing keeps it, as SwiftUI may dismiss before confirming.
struct ServerSwitchPrompt {
    private(set) var shown: ServerSwitchRequest?
    private var generation = 0

    /// Opens a newer link with `open` (the router), first replacing the request shown, wherever
    /// the link goes. Returns what `open` returned.
    mutating func open(_ link: DeepLink, with open: (DeepLink) -> Bool) -> Bool {
        generation += 1
        shown = nil
        return open(link)
    }

    /// Replaces the request shown, and the switch `router` holds to ask about, for a newer
    /// arrival that may open nothing: a continued Handoff activity (``SceneLinks/handoffArrivals``).
    @MainActor mutating func supersede(in router: Router) {
        generation += 1
        shown = nil
        router.pendingServerSwitch = nil
    }

    mutating func present(_ link: DeepLink, for connection: ServerConnectionDTO) {
        generation += 1
        shown = ServerSwitchRequest(link: link, connection: connection, generation: generation)
    }

    mutating func dismiss(_ request: ServerSwitchRequest) {
        if request.generation == generation { shown = nil }
    }

    /// Takes `request` to confirm, once: `false` if taken already or a newer one was presented.
    mutating func take(_ request: ServerSwitchRequest) -> Bool {
        guard request.generation == generation else { return false }
        generation += 1
        shown = nil
        return true
    }
}

/// A link for another saved server (``Router/pendingServerSwitch``): dropped without a session,
/// or asked about, then switched to through the lifecycle, the root keeping the link.
@MainActor
struct ServerSwitchConfirmation {
    let lifecycle: SessionLifecycle
    let accounts: AccountManager?

    /// The saved connection `link` is for, or `nil` if it isn't saved, or is signed out.
    func connection(for link: DeepLink) -> ServerConnectionDTO? {
        guard let id = link.serverID.flatMap(UUID.init(uuidString:)) else { return nil }
        return accounts?.connections.first { $0.id == id && !$0.isDisconnected && $0.signedOutAt == nil }
    }

    /// Takes the router's pending link to ask about, or `nil` if a newer link replaced it or it
    /// was dropped: its server isn't saved or has no session (``AccountManager/hasSession(_:)``).
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

    /// Switches to `request`'s server if the prompt still shows (or showed) it, in its own task
    /// (``AccountActions/switchAccount(to:)``), and hands the link to the root to open after.
    /// - Returns: The switch's task, or `nil`, changing nothing, when the request was replaced
    ///   (also by a link the root holds but the scene hasn't opened) or the session isn't ready.
    @discardableResult
    func confirm(
        _ request: ServerSwitchRequest, prompt: inout ServerSwitchPrompt, reopen: LinkReopener
    ) -> Task<SwitchOutcome, Never>? {
        guard lifecycle.acceptsAccountChanges, prompt.take(request), reopen.beginSwitch(request.link) else {
            return nil
        }
        guard
            let switching = AccountActions(lifecycle: lifecycle, accounts: accounts)
                .switchAccount(to: request.connection.id)
        else {
            reopen.finishSwitch(.failed(.other))
            return nil
        }
        return Task {
            let outcome = await switching.value
            reopen.finishSwitch(outcome)
            return outcome
        }
    }
}

/// Asks before opening a link for another saved server; reads the environment `RootView` sets.
struct ServerSwitchConfirmationModifier: ViewModifier {
    let router: Router
    let reopen: LinkReopener
    /// The scene's prompt, which the host also replaces when it opens a link.
    @Binding var prompt: ServerSwitchPrompt
    @Environment(SessionLifecycle.self) private var lifecycle: SessionLifecycle?
    @Environment(AccountManager.self) private var accounts: AccountManager?
    @State private var switchFailed = false
    @State private var switchFailure = SwitchFailure.other

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
                            if let switching, case .failed(let failure) = await switching.value {
                                switchFailure = failure
                                switchFailed = true
                            }
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
                .switchServerFailedAlert(isPresented: $switchFailed, failure: switchFailure)
        } else {
            content
        }
    }
}

extension View {
    /// Tells the user why a switch failed; the account, shell and alert stay.
    func switchServerFailedAlert(isPresented: Binding<Bool>, failure: SwitchFailure) -> some View {
        alert(Text(verbatim: failure.message), isPresented: isPresented) {
            Button(role: .cancel) {
            } label: {
                Text(verbatim: L10n.string("ButtonOk"))
            }
        }
    }
}
