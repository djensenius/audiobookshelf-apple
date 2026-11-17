import ABSAppModel
import ABSUI
import SwiftUI
import Testing

@testable import Audiobookshelf

@Suite struct LibraryCommandsTests {
    @Test func librariesTakeOptionCommandDigitsUpToNine() {
        let shortcuts = (1...9).map {
            LibraryCommandItem(id: "lib\($0)", name: "Library \($0)", shortcutDigit: $0, isCurrent: false).shortcut
        }
        #expect(
            shortcuts
                == (1...9).map { KeyboardShortcut(KeyEquivalent(Character("\($0)")), modifiers: [.option, .command]) })
        #expect(
            LibraryCommandItem(id: "lib10", name: "Library 10", shortcutDigit: nil, isCurrent: false).shortcut == nil)
    }

    @Test func shortcutsAreDistinctFromTheOtherMenus() {
        let library = (1...9).compactMap {
            LibraryCommandItem(id: "\($0)", name: "\($0)", shortcutDigit: $0, isCurrent: false).shortcut
        }
        let others =
            GoCommand.allCases.map(\.shortcut) + PlaybackCommand.allCases.map(\.shortcut) + [
                ShowNowPlayingMenuItem.shortcut
            ]
        #expect(Set(library).isDisjoint(with: others))
    }

    @Test func menuTitleResolves() {
        #expect(L10n.string(LibraryCommands.titleKey) != LibraryCommands.titleKey)
    }
}
