import Foundation
import Testing

@testable import ABSUI

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
        #expect(L10n.string("ButtonCancel", locale: Locale(identifier: "zh-Hant")) == "取消")
        #expect(L10n.string("ButtonCancel", locale: Locale(identifier: "nb")) == "Avbryt")
    }

    /// The playback history's day headers (`PlaybackHistoryView`).
    @Test func historyDayHeaders() {
        let english = Locale(identifier: "en")
        #expect(L10n.string("LabelToday", locale: english) == "Today")
        #expect(L10n.string("LabelYesterday", locale: english) == "Yesterday")
    }

    @Test func formatsPositionalArguments() {
        let value = L10n.string("LabelNumEpisodesIncomplete", "3", "1", locale: Locale(identifier: "en"))
        #expect(value == "3 episodes, 1 incomplete")
    }

    /// A plural key picks its form by the count and formats the count for the locale, with or without a locale,
    /// and in a locale without a translation.
    @Test func pluralPicksTheFormForTheCount() {
        let english = Locale(identifier: "en_US")
        #expect(L10n.plural("SharedBookCount", count: 1, locale: english) == "1 book")
        #expect(L10n.plural("SharedBookCount", count: 2, locale: english) == "2 books")
        #expect(L10n.plural("SharedBookCount", count: 1_234, locale: english) == "1,234 books")
        #expect(L10n.plural("SharedBookCount", count: 1_234, locale: Locale(identifier: "de")) == "1.234 books")
        #expect(L10n.plural("SharedBookCount", count: 1) == "1 book")
        #expect(L10n.plural("SharedBookCount", count: 5) == "5 books")
    }

    /// A locale without a translation of a plural uses the English forms by English rules, not its own: Japanese
    /// has only `other` ("1 books") and French puts 0 in `one` ("0 book"). The count keeps the locale's grouping.
    @Test(arguments: ["ja", "fr", "de"])
    func untranslatedPluralKeepsEnglishRules(identifier: String) {
        let locale = Locale(identifier: identifier)
        #expect(L10n.plural("SharedBookCount", count: 1, locale: locale) == "1 book")
        #expect(L10n.plural("SharedBookCount", count: 0, locale: locale) == "0 books")
        #expect(L10n.plural("SharedBookCount", count: 2, locale: locale) == "2 books")
        let grouped = 1_234.formatted(.number.locale(locale))
        #expect(L10n.plural("SharedBookCount", count: 1_234, locale: locale) == "\(grouped) books")
        #expect(identifier != "ja" || grouped == "1,234")
    }

    /// A translated plural uses its own forms by its language's rules (French: 0 and 1 are `one`); a locale without
    /// one falls back to English.
    @Test func translatedPluralUsesItsOwnRules() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "L10nTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ localization: String, _ one: String, _ other: String) throws {
            let entry: [String: Any] = [
                "Count": [
                    "NSStringLocalizedFormatKey": "%#@value@",
                    "value": [
                        "NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld",
                        "one": one, "other": other,
                    ],
                ]
            ]
            let folder = directory.appending(path: "\(localization).lproj")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: entry, format: .xml, options: 0)
                .write(to: folder.appending(path: "Localizable.stringsdict"))
        }
        try write("en", "%1$lld book", "%1$lld books")
        try write("fr", "%1$lld livre", "%1$lld livres")
        try FileManager.default.createDirectory(
            at: directory.appending(path: "ja.lproj"), withIntermediateDirectories: true)
        let bundle = try #require(Bundle(url: directory))
        let english = L10n.EnglishPlurals(bundle: bundle)
        func plural(_ count: Int, _ identifier: String) -> String {
            L10n.plural(
                "Count", count: count, arguments: [], locale: Locale(identifier: identifier), bundle: bundle,
                english: english)
        }

        #expect(plural(0, "fr") == "0 livre")
        #expect(plural(1, "fr") == "1 livre")
        #expect(plural(2, "fr") == "2 livres")
        #expect(plural(1, "ja") == "1 book")
        #expect(plural(0, "ja") == "0 books")
        #expect(plural(1, "en") == "1 book")
        #expect(english.format("Missing", count: 1) == nil)
    }

    @Test func looksUpPreferredLocalization() {
        // The test runner has no localizations of its own, so it resolves to English.
        #expect(L10n.string("ButtonCancel") == "Cancel")
    }

    /// Every compiled locale has every key with a real value, so no lookup shows a key name,
    /// even without `L10n`'s English fallback.
    @Test func everyLocaleResolvesEveryKey() throws {
        func table(_ localization: String) -> [String: String]? {
            L10n.bundle.url(
                forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: localization
            )
            .flatMap { NSDictionary(contentsOf: $0) as? [String: String] }
        }
        let keys = try #require(table("en")).keys
        let locales = L10n.bundle.localizations.filter { $0 != "Base" }
        #expect(locales.count > 1)
        #expect(keys.count > 1)
        var unresolved: [String] = []
        for locale in locales {
            let values = table(locale) ?? [:]
            unresolved += keys.filter { values[$0] == nil || values[$0] == $0 }.map { "\(locale): \($0)" }
            // Spot-check the lookup path itself once per locale.
            if let key = keys.first, L10n.localized(key, locale: Locale(identifier: locale)) == key {
                unresolved.append("\(locale): \(key) (lookup)")
            }
        }
        #expect(unresolved.isEmpty)
    }

    @Test func stringDropsMarkup() {
        let value = L10n.string("MessageAudiobookshelfServerRequired", locale: Locale(identifier: "zh-Hans"))
        #expect(!value.contains("*") && !value.contains("^[") && !value.contains("]()"))
        #expect(value.hasPrefix("重要提示！此应用"))
        #expect(L10n.string("HeaderWelcome", "Ada", locale: Locale(identifier: "en")) == "Welcome, Ada")
    }

    @Test func stringKeepsPlainValuesAndLiteralArguments() {
        #expect(L10n.string("ButtonCancel", locale: Locale(identifier: "en")) == "Cancel")
        // The value has markup, but arguments are never parsed: their asterisks and
        // brackets stay literal.
        let value = L10n.string("HeaderWelcome", "*Ada* [x](y)", locale: Locale(identifier: "en"))
        #expect(value == "Welcome, *Ada* [x](y)")
        let plain = L10n.string("MessageConfirmDeleteServerEpisode", "*Ep*", locale: Locale(identifier: "en"))
        #expect(plain.hasPrefix("Are you sure you want to delete episode \"*Ep*\" from the server?\n"))
    }

    /// Bold ending in punctuation and followed by a letter, which plain `**x**` can't close.
    @Test(arguments: [("zh-Hans", "重要提示！", "此应用"), ("zh-Hant", "重要！", "此應用程式")])
    func attributedBoldsBeforeCJKText(locale: String, bold: String, following: String) {
        let value = L10n.attributed("MessageAudiobookshelfServerRequired", locale: Locale(identifier: locale))
        let text = String(value.characters)
        #expect(!text.contains("*") && !text.contains("^["))
        #expect(text.hasPrefix(bold + following))
        let boldRuns = value.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(boldRuns.map { String(value[$0.range].characters) } == [bold])
    }

    @Test func attributedRendersMarkdownFromFormatOnly() throws {
        let argument = "[x](https://evil) a_b_"
        let value = L10n.attributed("HeaderWelcome", argument, locale: Locale(identifier: "en"))
        #expect(String(value.characters) == "Welcome, \(argument)")
        #expect(value.runs.allSatisfy { $0.link == nil })
        let range = try #require(value.range(of: argument))
        #expect(value[range].runs.allSatisfy { $0.inlinePresentationIntent == .stronglyEmphasized })
    }

    @Test func attributedPreservesLineBreaks() {
        let value = L10n.attributed("MessageConfirmDeleteServerEpisode", "*Ep*", locale: Locale(identifier: "en"))
        #expect(
            String(value.characters)
                == "Are you sure you want to delete episode \"*Ep*\" from the server?\nWarning: This will delete the audio file."
        )
    }
}
