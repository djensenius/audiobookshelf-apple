import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

@Suite struct ReaderThemeTests {
    @Test(arguments: [
        (ReaderSettings.Theme.matchSystem, ReaderAppearance.light, ReaderTheme.light),
        (.matchSystem, .dark, .dark),
        (.light, .dark, .light),
        (.dark, .light, .dark),
        (.black, .light, .black),
        (.sepia, .dark, .sepia),
    ])
    func themesResolve(theme: ReaderSettings.Theme, appearance: ReaderAppearance, expected: ReaderTheme) {
        #expect(ReaderTheme(theme, resolvedAppearance: appearance) == expected)
    }

    /// The legacy `EpubReader.vue` `themeRules` strings, character for character.
    @Test(arguments: [
        (ReaderSettings.Theme.light, "#000", "rgb(255, 255, 255)"),
        (.dark, "#fff", "rgb(35 35 35)"),
        (.black, "#fff", "rgb(0 0 0)"),
        // Sepia isn't in the legacy app; these are the web client's colours.
        (.sepia, "#5b4636", "rgb(244, 236, 216)"),
    ])
    func rulesMatchLegacy(theme: ReaderSettings.Theme, color: String, background: String) {
        let rules = ReaderTheme.themeRules(for: ReaderSettings(theme: theme), resolvedAppearance: .light)
        #expect(
            rules == [
                "*": [
                    "color": "\(color)!important",
                    "background-color": "\(background)!important",
                    "line-height": "115%!important",
                    "-webkit-text-stroke": "0px \(color)!important",
                ],
                "a": ["color": "\(color)!important"],
            ])
    }

    @Test func matchSystemRulesFollowTheAppearance() {
        let settings = ReaderSettings()
        #expect(
            ReaderTheme.themeRules(for: settings, resolvedAppearance: .dark)
                == ReaderTheme.themeRules(for: ReaderSettings(theme: .dark), resolvedAppearance: .light))
        #expect(
            ReaderTheme.themeRules(for: settings, resolvedAppearance: .light)
                == ReaderTheme.themeRules(for: ReaderSettings(theme: .light), resolvedAppearance: .dark))
    }

    @Test func rulesCarryLineSpacingAndStroke() {
        let settings = ReaderSettings(theme: .dark, fontFamily: .sansSerif, lineSpacing: 200, textStroke: 150)
        let rules = ReaderTheme.themeRules(for: settings, resolvedAppearance: .light)
        #expect(rules["*"]?["line-height"] == "200%!important")
        #expect(rules["*"]?["-webkit-text-stroke"] == "1.5px #fff!important")
    }

    /// A book's `body.reader { font-family: X !important }` beats any `body` theme rule on
    /// specificity, so the font goes in the payload for `rendition.themes.font` (an inline
    /// `!important` override, as in the legacy reader) and no theme rule sets it.
    @Test(arguments: ReaderSettings.FontFamily.allCases)
    func theFontIsAnOverrideNotARule(fontFamily: ReaderSettings.FontFamily) {
        let settings = ReaderSettings(fontFamily: fontFamily)
        let payload = ReaderSettingsPayload(settings: settings, resolvedAppearance: .light)
        #expect(payload.fontFamily == fontFamily)
        #expect(payload.themeRules.values.allSatisfy { $0["font-family"] == nil })
    }

    /// `textStroke / 100` as JavaScript prints it.
    @Test(arguments: [
        (0, "0"), (5, "0.05"), (10, "0.1"), (50, "0.5"), (100, "1"), (115, "1.15"), (300, "3"), (-5, "-0.05"),
    ])
    func strokeIsWrittenAsJavaScriptWould(hundredths: Int, expected: String) {
        #expect(ReaderTheme.pixels(hundredths: hundredths) == expected)
    }

    @Test func payloadMatchesTheBridgeContract() throws {
        let settings = ReaderSettings(
            theme: .matchSystem, fontFamily: .sansSerif, fontScale: 120, lineSpacing: 150, textStroke: 10,
            spread: .none)
        let payload = ReaderSettingsPayload(settings: settings, resolvedAppearance: .dark, gap: 24)
        let data = try JSONEncoder().encode(payload)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(
            Set(object.keys)
                == ["theme", "fontFamily", "fontScale", "lineSpacing", "textStroke", "spread", "gap", "themeRules"])
        #expect(object["theme"] as? String == "dark")
        #expect(object["fontFamily"] as? String == "sans-serif")
        #expect(object["fontScale"] as? Int == 120)
        #expect(object["lineSpacing"] as? Int == 150)
        #expect(object["textStroke"] as? Int == 10)
        #expect(object["spread"] as? String == "none")
        #expect(object["gap"] as? Double == 24)
        let rules = try #require(object["themeRules"] as? [String: [String: String]])
        #expect(rules == ReaderTheme.themeRules(for: settings, resolvedAppearance: .dark))
    }

    @Test func payloadGapDefaultsToZeroAndRejectsNonsense() {
        let settings = ReaderSettings()
        #expect(ReaderSettingsPayload(settings: settings, resolvedAppearance: .light).gap == 0)
        #expect(ReaderSettingsPayload(settings: settings, resolvedAppearance: .light, gap: -3).gap == 0)
        #expect(ReaderSettingsPayload(settings: settings, resolvedAppearance: .light, gap: .nan).gap == 0)
        #expect(ReaderSettingsPayload(settings: settings, resolvedAppearance: .light, gap: .infinity).gap == 0)
    }

    @Test func everyOptionHasALocalizationKey() {
        #expect(ReaderSettings.Theme.allCases.map(\.titleKey).allSatisfy { $0.hasPrefix("LabelTheme") })
        #expect(Set(ReaderSettings.Theme.allCases.map(\.titleKey)).count == ReaderSettings.Theme.allCases.count)
        #expect(ReaderSettings.FontFamily.allCases.map(\.titleKey) == ["LabelFontFamilySerif", "LabelFontFamilySans"])
        #expect(ReaderSettings.Spread.allCases.map(\.titleKey) == ["LabelLayoutAuto", "LabelLayoutSinglePage"])
        #expect(ReaderSettingsLabel.textStroke.titleKey == "LabelFontBoldness")
    }
}
