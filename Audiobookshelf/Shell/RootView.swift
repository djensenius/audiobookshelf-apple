import ABSAppModel
import ABSUI
import SwiftUI

/// The root of every window scene: shows what the session lifecycle's gate says (ADR 0004).
///
/// Links reach the scene here, from `onOpenURL` and Handoff. A link waits in ``pendingLink`` until
/// a signed-in host can open it, so a cold launch from a link, or a link that arrives while the
/// session restores, isn't lost.
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
            .onOpenURL { url in
                if let link = DeepLink(url: url) { pendingLink = link }
            }
            .onContinueUserActivity(DeepLink.handoffActivityType) { activity in
                if let link = DeepLink(handoff: activity.userInfo) { pendingLink = link }
            }
    }

    @ViewBuilder private var content: some View {
        switch lifecycle.gate {
        case .launching, .signingOut:
            LoadingView()
        case .connect:
            SignedOutPlaceholder()
        case .ready(let identity, _), .switching(from: let identity):
            // A switch keeps the old shell on screen until the next session has started, so a
            // sign-in presented from it isn't torn down.
            SceneRouterHost(identity: identity, player: player, pendingLink: $pendingLink)
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
