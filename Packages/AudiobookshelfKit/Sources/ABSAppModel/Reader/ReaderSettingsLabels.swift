import ABSCore

// Localization keys for the reader settings (resolve with `L10n.string`). The option names are
// the legacy reader's (`components/readers/Reader.vue`); "match system" and sepia are native.

extension ReaderSettings.Theme {
    public var titleKey: String {
        switch self {
        case .matchSystem: "LabelThemeSystem"
        case .light: "LabelThemeLight"
        case .dark: "LabelThemeDark"
        case .black: "LabelThemeBlack"
        case .sepia: "LabelThemeSepia"
        }
    }
}

extension ReaderSettings.FontFamily {
    public var titleKey: String {
        switch self {
        case .serif: "LabelFontFamilySerif"
        case .sansSerif: "LabelFontFamilySans"
        }
    }
}

extension ReaderSettings.Spread {
    public var titleKey: String {
        switch self {
        case .auto: "LabelLayoutAuto"
        case .none: "LabelLayoutSinglePage"
        }
    }
}

/// The settings' own labels, as in the legacy settings sheet.
public enum ReaderSettingsLabel: String, CaseIterable, Sendable {
    case theme = "LabelTheme"
    case fontFamily = "LabelFontFamily"
    case fontScale = "LabelFontScale"
    case lineSpacing = "LabelLineSpacing"
    case textStroke = "LabelFontBoldness"
    case spread = "LabelLayout"

    public var titleKey: String { rawValue }
}
