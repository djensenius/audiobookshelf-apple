import ABSAppModel
import ABSUI
import SwiftUI
import Testing

@testable import Audiobookshelf

@Suite struct GoCommandsTests {
    @Test func tabsTakeCommandOneToFiveInMenuOrderAndBackTakesBracket() {
        #expect(
            GoCommand.tabs.map(\.shortcut) == [
                KeyboardShortcut("1"), KeyboardShortcut("2"), KeyboardShortcut("3"), KeyboardShortcut("4"),
                KeyboardShortcut("5"),
            ])
        #expect(GoCommand.back.shortcut == KeyboardShortcut("[", modifiers: .command))
        #expect(GoCommand.allCases.allSatisfy { $0.shortcut.modifiers == .command })
    }

    @Test func itemsUseTheirTabsTitles() {
        #expect(GoCommand.tabs.map(\.titleKey) == GoCommand.tabs.compactMap(\.tab?.titleKey))
        #expect(GoCommand.back.titleKey == "ButtonBack")
    }

    @Test(arguments: ["HeaderGo"] + GoCommand.allCases.map(\.titleKey))
    func menuStringsResolve(key: String) {
        #expect(L10n.string(key) != key, "\(key) is missing from the catalog")
    }
}
