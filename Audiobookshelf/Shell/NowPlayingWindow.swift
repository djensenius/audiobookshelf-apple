#if os(macOS)
    import ABSAppModel
    import SwiftUI

    /// The macOS full player: ``NowPlayingView`` in its own window, which ``PlayerSlot`` opens when
    /// a scene's `Router/isFullPlayerPresented` turns on. One window serves every scene, since
    /// they share the player. Its toolbar's minimize button closes it, and so does the session
    /// ending.
    ///
    /// The player is rebuilt for each account session, so a switch discards pending forms such as
    /// the bookmark editor, which would otherwise submit through the next session's store, even
    /// when the window never saw `hasSession` turn off in between.
    struct NowPlayingWindow: View {
        static let id = "now-playing"

        let player: PlayerViewModel
        @Environment(\.dismissWindow) private var dismissWindow
        @Environment(\.bookmarkStore) private var bookmarks

        var body: some View {
            NowPlayingView(model: player)
                // A failed Playback menu command shows here while this window is focused; inside
                // the session's subtree, so a switch drops the last session's alert.
                .playbackCommandAlert()
                .id(Self.sessionKey(bookmarks))
                .onChange(of: player.hasSession, initial: true) { _, hasSession in
                    if !hasSession { dismissWindow(id: Self.id) }
                }
        }

        /// The running session's key: its bookmark store, which each session makes anew; `nil`
        /// between sessions. The view graph holds the rendered store until it renders the next, so
        /// the two can't share an address.
        static func sessionKey(_ bookmarks: BookmarkStore?) -> ObjectIdentifier? {
            bookmarks.map(ObjectIdentifier.init)
        }
    }
#endif
