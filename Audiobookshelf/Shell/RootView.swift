import ABSAppModel
import ABSUI
import SwiftUI

/// The root of every window scene: shows what the session lifecycle's gate says (ADR 0004).
///
/// Links reach the scene here, from `onOpenURL` and Handoff. A link waits in ``pendingLink`` until
/// a signed-in host can open it, so a cold launch from a link, or a link that arrives while the
/// session restores, isn't lost. Only a ready session's shell gets the binding: during an account
/// switch the outgoing shell has none, so the incoming account's shell takes the link. Nothing
/// waits while signed out or without a store (``SceneContent/holdsLinks``), so a link is never kept
/// through a sign-in to open later, for whichever account signed in.
struct RootView: View {
    let lifecycle: SessionLifecycle
    let player: any PlayerSlotState

    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingLink: DeepLink?

    var body: some View {
        content
            .task { await lifecycle.start() }
            .onChange(of: scenePhase) { _, phase in
                Task { await lifecycle.handle(scenePhase: SessionScenePhase(phase)) }
            }
            .onChange(of: lifecycle.gate) { _, gate in
                if !SceneContent(gate).holdsLinks { pendingLink = nil }
            }
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

    private func receive(_ link: DeepLink) {
        if SceneContent(lifecycle.gate).holdsLinks { pendingLink = link }
    }

    @ViewBuilder private var content: some View {
        switch SceneContent(lifecycle.gate) {
        case .loading:
            LoadingView()
        case .connect:
            SignedOutPlaceholder()
        case .shell(let identity, let opensLinks):
            // A switch keeps the old shell on screen until the next session has started, so a
            // sign-in presented from it isn't torn down. It is the same case as a ready session,
            // so the shell, its router and its scene storage survive until the identity changes.
            SceneRouterHost(
                identity: identity, player: player, pendingLink: opensLinks ? $pendingLink : .constant(nil)
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
    RootView(lifecycle: SessionLifecycle(source: SignedOutAccountSource()), player: PlaceholderPlayerState())
}

#Preview("Store unavailable") {
    RootView(
        lifecycle: SessionLifecycle(storeUnavailable: CocoaError(.fileWriteOutOfSpace)),
        player: PlaceholderPlayerState())
}
