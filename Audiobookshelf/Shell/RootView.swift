import ABSAppModel
import ABSUI
import SwiftUI

/// The root of every window scene: shows what the session lifecycle's gate says (ADR 0004).
///
/// Links reach the scene here, from `onOpenURL` and Handoff. A link waits in ``links``,
/// tagged with ``SessionLifecycle/linkEpoch``, until a signed-in host can open it, so a cold launch
/// from a link, or a link that arrives while the session restores, isn't lost. Only a ready
/// session's shell gets the binding: during an account switch the outgoing shell has none, so the
/// incoming account's shell takes the link. Nothing arriving while signed out, signing out or
/// without a store is kept (``PendingLink/init(_:arrivingAt:epoch:)``), and the binding hands the
/// host a link only while the epoch is the one it arrived in, so a link queued for one account
/// never opens for another, even when this view didn't render the gates in between.
///
/// The lifecycle and the accounts are in the environment of everything below, so a screen such
/// as the Account tab reads them with `@Environment` instead of through its initializer, and so is
/// the shown account's `serverID` (``SceneContent/serverID``).
struct RootView: View {
    let lifecycle: SessionLifecycle
    let player: any PlayerSlotState
    let accounts: AccountManager?

    @Environment(\.scenePhase) private var scenePhase
    @State private var links = SceneLinks()
    /// Why a switch ended signed out; the old shell, which would have said so, is gone.
    @State private var switchSignedOutMessage: String?

    var body: some View {
        content
            .environment(lifecycle)
            .environment(accounts)
            .environment(\.serverID, SceneContent(lifecycle.gate).serverID)
            .task { await lifecycle.start() }
            // A count, not the gate: SwiftUI can coalesce the switch's gates.
            .onChange(of: lifecycle.signedOutSwitches) {
                switchSignedOutMessage = accounts?.signedOutSwitchMessage ?? L10n.string("MessageSwitchServerSignedOut")
            }
            .alert(
                Text(verbatim: switchSignedOutMessage ?? ""),
                isPresented: Binding {
                    switchSignedOutMessage != nil
                } set: {
                    if !$0 { switchSignedOutMessage = nil }
                }
            ) {
                Button(role: .cancel) {
                } label: {
                    Text(verbatim: L10n.string("ButtonOk"))
                }
            }
            .onChange(of: scenePhase) { _, phase in
                Task { await lifecycle.handle(scenePhase: SessionScenePhase(phase)) }
            }
            // Only a stale link goes: one that arrived after the bump carries the new epoch.
            .onChange(of: lifecycle.linkEpoch) { _, epoch in links.dropStale(atEpoch: epoch) }
            .onOpenURL { url in
                if let link = DeepLink(url: url) { receive(link) }
            }
            .onContinueUserActivity(DeepLink.handoffActivityType) { activity in
                if let link = DeepLink(handoff: activity.userInfo) { receive(link) }
            }
            // A link or a continued activity goes to a window that exists instead of opening a new
            // one (macOS, and iPad windows).
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    }

    /// One link waits at a time: the last one received wins, including over a confirmed server
    /// switch's link (``SceneLinks``).
    private func receive(_ link: DeepLink) {
        links.receive(link, gate: lifecycle.gate, epoch: lifecycle.linkEpoch)
    }

    /// Checked when the host reads it, not only when the epoch changes: SwiftUI orders a new
    /// host's `onAppear` and this view's `onChange` arbitrarily.
    private var linkBinding: Binding<DeepLink?> {
        Binding(
            get: { links.link(atEpoch: lifecycle.linkEpoch) },
            set: { if $0 == nil { links.clearPending() } }
        )
    }

    @ViewBuilder private var content: some View {
        switch SceneContent(lifecycle.gate) {
        case .loading, .signingOut:
            LoadingView()
        case .connect:
            if let accounts {
                ConnectFlowView(accounts: accounts)
            } else {
                SignedOutPlaceholder()
            }
        case .shell(let identity, let opensLinks):
            // A switch keeps the old shell on screen until the next session has started, so a
            // sign-in presented from it isn't torn down. It is the same case as a ready session,
            // so the shell, its router and its scene storage survive until the identity changes.
            // A confirmed switch to another server hands its link here, to open after the
            // switch, so the link carries the new account's epoch and reaches the new host.
            SceneRouterHost(
                identity: identity, player: player, pendingLink: opensLinks ? linkBinding : .constant(nil),
                reopen: LinkReopener(
                    beginSwitch: { links.beginSwitch(with: $0) },
                    finishSwitch: {
                        links.finishSwitch(succeeded: $0, gate: lifecycle.gate, epoch: lifecycle.linkEpoch)
                    })
            )
            .id(identity)
        case .storeUnavailable:
            ErrorStateView(
                title: L10n.string("MessageStoreUnavailable"),
                message: L10n.string("MessageStoreUnavailableHelp"),
                systemImage: "externaldrive.badge.exclamationmark"
            )
        }
    }
}

extension SceneContent {
    /// The connection whose shell is on screen, for `\.serverID`: the ready account's, or the
    /// outgoing account's while a switch keeps its shell up; `nil` when no shell is shown.
    var serverID: UUID? {
        if case .shell(let identity, _) = self { identity.connectionID } else { nil }
    }
}

extension SessionScenePhase {
    fileprivate init(_ phase: ScenePhase) {
        switch phase {
        case .active: self = .active
        case .inactive: self = .inactive
        case .background: self = .background
        @unknown default: self = .inactive
        }
    }
}

#Preview("Signed out") {
    RootView(
        lifecycle: SessionLifecycle(source: SignedOutAccountSource()), player: PlaceholderPlayerState(), accounts: nil)
}

#Preview("Store unavailable") {
    RootView(
        lifecycle: SessionLifecycle(storeUnavailable: CocoaError(.fileWriteOutOfSpace)),
        player: PlaceholderPlayerState(), accounts: nil)
}
