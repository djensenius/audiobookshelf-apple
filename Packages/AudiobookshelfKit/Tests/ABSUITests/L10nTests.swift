import ABSUI
import Foundation
import Testing

@Suite struct L10nTests {
    @Test func looksUpGermanString() {
        #expect(L10n.string("ButtonCancel", locale: Locale(identifier: "de")) == "Abbrechen")
    }

    @Test func looksUpEnglishString() {
        #expect(L10n.string("ButtonCancel", locale: Locale(identifier: "en")) == "Cancel")
    }

    @Test func mappedLocalesResolve() {
        #expect(L10n.string("ButtonCancel", locale: Locale(identifier: "pt-BR")) == "Cancelar")
        #expect(L10n.string("ButtonCancel", locale: Locale(identifier: "zh-Hans")) == "取消")
        #expect(L10n.string("ButtonCancel", locale: Locale(identifier: "nb")) == "Avbryt")
    }

    @Test func formatsPositionalArguments() {
        let value = L10n.string("LabelNumEpisodesIncomplete", "3", "1", locale: Locale(identifier: "en"))
        #expect(value == "3 episodes, 1 incomplete")
    }

    @Test func fallsBackToEnglishForUntranslatedString() {
        #expect(L10n.string("ButtonAllow", locale: Locale(identifier: "is")) == "Allow")
    }

    @Test func fallsBackToEnglishForUntranslatedFormat() {
        // fi's HeaderWelcome has a malformed placeholder, so the importer skips it.
        let value = L10n.string("HeaderWelcome", "Ada", locale: Locale(identifier: "fi"))
        #expect(value == "Welcome, **Ada**")
    }

    @Test func looksUpPreferredLocalization() {
        // The test runner has no localizations of its own, so it resolves to English.
        #expect(L10n.string("ButtonCancel") == "Cancel")
    }
}
