import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The Library menu (ADR 0004), on a Mac and in the iPad hardware keyboard's ⌘ overlay: one item
/// per library of the focused scene's account, with ⌥⌘1 to ⌥⌘9 for the first nine and a checkmark on
/// the scene's library. Choosing one switches the scene to it, as the library picker does.
/// ``LibraryCommand`` has the rules; the menu is hidden while it has no items, such as when no
/// signed-in scene is focused.
struct LibraryCommands: Commands {
    /// The shared libraries; `nil` without a data stack.
    let store: LibraryStore?
    /// For whether the user may add podcasts, which the library's sections follow.
    let accounts: AccountManager?
    @FocusedValue(Router.self) private var router: Router?

    var body: some Commands {
        let items = LibraryCommand.items(router: router, store: store)
        if !items.isEmpty {
            CommandMenu(Text(verbatim: L10n.string(Self.titleKey))) {
                ForEach(items) { item in
                    Toggle(
                        isOn: Binding(
                            get: { item.isCurrent },
                            set: { _ in
                                LibraryCommand.select(
                                    item.id, router: router, store: store, canAddPodcast: accounts?.canAddPodcast)
                            })
                    ) {
                        Text(verbatim: item.name)
                    }
                    .keyboardShortcut(item.shortcut)
                }
            }
        }
    }

    nonisolated static let titleKey = "HeaderLibrary"
}

extension LibraryCommandItem {
    /// ⌥⌘ and the item's digit, for the first nine libraries; `nil` after them.
    var shortcut: KeyboardShortcut? {
        shortcutDigit.map { KeyboardShortcut(KeyEquivalent(Character(String($0))), modifiers: [.option, .command]) }
    }
}
