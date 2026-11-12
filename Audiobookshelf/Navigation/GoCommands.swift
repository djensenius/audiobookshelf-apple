import ABSAppModel
import ABSUI
import SwiftUI

/// The Go menu (ADR 0004), on a Mac and in the iPad hardware keyboard's ⌘ overlay: ⌘1 to ⌘5 select
/// Home, Library, Search, Downloads and Account, and Back (⌘[) pops the selected tab's top screen, in
/// the focused scene's ``Router``. ``GoCommand`` has the rules: every item is disabled while no
/// signed-in scene is focused, and Back also at the stack's root.
struct GoCommands: Commands {
    @FocusedValue(Router.self) private var router: Router?

    var body: some Commands {
        CommandMenu(Text(verbatim: L10n.string("HeaderGo"))) {
            ForEach(GoCommand.tabs, id: \.self) { command in
                item(command)
            }
            Divider()
            item(.back)
        }
    }

    private func item(_ command: GoCommand) -> some View {
        Button {
            command.perform(in: router)
        } label: {
            Text(verbatim: L10n.string(command.titleKey))
        }
        .keyboardShortcut(command.shortcut)
        .disabled(!command.isEnabled(in: router))
    }
}

extension GoCommand {
    /// The key of the item's title in the string catalog: the tab's own title, or Back.
    var titleKey: String {
        tab?.titleKey ?? "ButtonBack"
    }

    /// ⌘1 to ⌘5 for the tabs in menu order, and ⌘[ for Back, like a browser.
    var shortcut: KeyboardShortcut {
        switch self {
        case .home: KeyboardShortcut("1")
        case .library: KeyboardShortcut("2")
        case .search: KeyboardShortcut("3")
        case .downloads: KeyboardShortcut("4")
        case .account: KeyboardShortcut("5")
        case .back: KeyboardShortcut("[")
        }
    }
}
