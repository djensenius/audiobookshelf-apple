import ABSAppModel
import ABSUI
import SwiftUI

/// Cmd+F, in the Edit menu on a Mac and with a hardware keyboard on iPad: opens the focused
/// scene's Search tab at its root and focuses the search field (``Router/requestSearchFocus()``).
/// Disabled while the focused scene has no router (signed out).
///
/// It replaces the system's text-editing group (Find, Spelling and Grammar, Substitutions,
/// Transformations, Speech), which would otherwise hold a second Cmd+F item. The app has no
/// document text to find in or proofread: its text fields are addresses, credentials, header
/// values and the search field itself.
struct SearchCommands: Commands {
    @FocusedValue(Router.self) private var router: Router?

    var body: some Commands {
        CommandGroup(replacing: .textEditing) {
            Button {
                router?.requestSearchFocus()
            } label: {
                Text(verbatim: L10n.string("ButtonSearch"))
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(router == nil)
        }
    }
}
