import ABSAppModel
import ABSUI
import SwiftUI

/// Hosts one window scene's navigation for one signed-in identity (ADR 0004). `RootView` gives it
/// `.id(identity)`, so a server or user switch builds a new host, a new router and a new
/// scene-storage entry; the key is the identity's ``SessionIdentity/snapshotKey``.
///
/// The scene's saved navigation is restored once, when the host appears: first the snapshot,
/// then the size class, then the link that launched the scene. The tabs show only after that, so
/// they never flash their defaults. The rules for when the scene may open a link or save are in
/// ``SceneNavigation``, which this view only wires to SwiftUI.
struct SceneRouterHost: View {
    let player: any PlayerSlotState
    /// A link waiting for a scene that can open it. The host takes it, opens it and clears it.
    @Binding var pendingLink: DeepLink?
    /// Hands a link back to the root, which holds it for the next account's host; used after a
    /// confirmed server switch (``ServerSwitchConfirmation``).
    let reopen: LinkReopener

    @State private var navigation: SceneNavigation
    @SceneStorage private var snapshot: Data?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    init(
        identity: SessionIdentity, player: any PlayerSlotState, pendingLink: Binding<DeepLink?>,
        reopen: LinkReopener = LinkReopener()
    ) {
        self.player = player
        _pendingLink = pendingLink
        self.reopen = reopen
        _navigation = State(initialValue: SceneNavigation(identity: identity))
        _snapshot = SceneStorage(identity.snapshotKey)
    }

    var body: some View {
        Group {
            if navigation.isRestored {
                MainTabView(router: navigation.router, player: player)
            } else {
                LoadingView()
            }
        }
        .modifier(ServerSwitchConfirmationModifier(router: navigation.router, reopen: reopen))
        .focusedSceneValue(navigation.router)
        .onAppear(perform: restoreOnce)
        .onChange(of: pendingLink) { openPendingLink() }
        // Written through as the navigation changes, so a quit or a crash loses at most the last
        // move. This runs after the restore has finished, so a link opened by it is saved too.
        .onChange(of: navigation.router.snapshot) { save() }
        // Also when the scene leaves the foreground, as a backup: `.inactive` counts, because
        // macOS may quit a scene without passing through `.background`.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { save() }
        }
    }

    private func restoreOnce() {
        let isCompact = horizontalSizeClass == .compact
        if navigation.restoreOnce(from: snapshot, isCompact: isCompact, opening: pendingLink) {
            pendingLink = nil
        }
    }

    private func openPendingLink() {
        if let link = pendingLink, navigation.open(link) { pendingLink = nil }
    }

    private func save() {
        if let data = navigation.snapshotToSave { snapshot = data }
    }
}

#Preview {
    SceneRouterHost(
        identity: SessionIdentity(connectionID: UUID(), userID: "preview"),
        player: PlaceholderPlayerState(),
        pendingLink: .constant(nil)
    )
}
