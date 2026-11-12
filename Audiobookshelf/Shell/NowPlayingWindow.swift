#if os(macOS)
    import ABSAppModel
    import SwiftUI

    /// The macOS full player: ``NowPlayingView`` in its own window, which ``PlayerSlot`` opens when
    /// a scene's `Router/isFullPlayerPresented` turns on. One window serves every scene, since
    /// they share the player. Its toolbar's minimize button closes it, and so does the session
    /// ending.
    struct NowPlayingWindow: View {
        static let id = "now-playing"

        let player: PlayerViewModel
        @Environment(\.dismissWindow) private var dismissWindow

        var body: some View {
            NowPlayingView(model: player)
                .onChange(of: player.hasSession, initial: true) { _, hasSession in
                    if !hasSession { dismissWindow(id: Self.id) }
                }
        }
    }
#endif
