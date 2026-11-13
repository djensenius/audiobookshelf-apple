import ABSAppModel
import SwiftUI

/// Sets `\.makeEbookProgress` to the current account session's ``EbookProgressFactory`` (#102,
/// #104), so the PDF and EPUB readers save every turn locally and send it through that session's
/// progress syncer. The factory refuses another connection's books, so a reader opened for one
/// account never writes under the next; between sessions it is `nil`.
///
/// `participant` is the shell's own (``RootView/playback(_:accounts:for:)``), or the app's for the
/// macOS reader windows, which aren't in a shell.
struct ReaderProgressEnvironment: ViewModifier {
    let participant: PlaybackSessionParticipant?

    func body(content: Content) -> some View {
        content.environment(\.makeEbookProgress, participant?.ebookProgress)
    }
}
