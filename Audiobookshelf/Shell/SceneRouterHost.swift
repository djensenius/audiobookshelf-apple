import ABSAppModel
import ABSUI
import SwiftUI

/// Hosts one window scene's ``Router`` for one signed-in identity (ADR 0004). `RootView` gives it
/// `.id(identity)`, so a server or user switch builds a new host, a new router and a new
/// scene-storage entry; the key is the identity's ``SessionIdentity/snapshotKey``.
///
/// The scene's saved navigation is restored once, when the host appears: first the snapshot,
/// then the size class, then the link that launched the scene. The tabs show only after that, so
/// they never flash their defaults.
struct SceneRouterHost: View {
    let player: any PlayerSlotState
    /// A link waiting for a scene that can open it. The host takes it, opens it and clears it.
    @Binding var pendingLink: DeepLink?

    @State private var router: Router
    @SceneStorage private var snapshot: Data?
    @State private var isRestored = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    init(identity: SessionIdentity, player: any PlayerSlotState, pendingLink: Binding<DeepLink?>) {
        self.player = player
        _pendingLink = pendingLink
        _router = State(initialValue: Router(identity: identity))
        _snapshot = SceneStorage(identity.snapshotKey)
    }

    var body: some View {
        Group {
            if isRestored {
                MainTabView(router: router, player: player)
            } else {
                LoadingView()
            }
        }
        .focusedSceneValue(router)
        .onAppear(perform: restoreOnce)
        .onChange(of: pendingLink) { openPendingLink() }
        .onChange(of: scenePhase) { _, phase in
            // Written when the scene leaves the foreground, not on every push. `.inactive` counts
            // too, because macOS may quit a scene without passing through `.background`. Never
            // before the restore, which would replace the saved snapshot with the defaults.
            if phase != .active, isRestored {
                snapshot = router.snapshotData
            }
        }
    }

    private func restoreOnce() {
        guard !isRestored else { return }
        router.restoreScene(from: snapshot, isCompact: horizontalSizeClass == .compact, opening: pendingLink)
        pendingLink = nil
        isRestored = true
    }

    private func openPendingLink() {
        guard isRestored, let link = pendingLink else { return }
        router.open(link)
        pendingLink = nil
    }
}

#Preview {
    SceneRouterHost(
        identity: SessionIdentity(connectionID: UUID(), userID: "preview"),
        player: PlaceholderPlayerState(),
        pendingLink: .constant(nil)
    )
}
