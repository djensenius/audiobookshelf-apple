import ABSCore

/// The system appearance "match system" follows. The caller passes it in, so this file needs
/// no SwiftUI: map `ColorScheme` or `NSAppearance` to it in the view.
public enum ReaderAppearance: Sendable, Hashable {
    case light
    case dark
}

/// A resolved reader theme: ``ReaderSettings/Theme`` with "match system" turned into light or
/// dark. The raw values are the bridge contract's `theme` strings.
public enum ReaderTheme: String, CaseIterable, Sendable, Hashable, Encodable {
    case light
    case dark
    case black
    case sepia

    public init(_ theme: ReaderSettings.Theme, resolvedAppearance: ReaderAppearance) {
        switch theme {
        case .matchSystem: self = resolvedAppearance == .dark ? .dark : .light
        case .light: self = .light
        case .dark: self = .dark
        case .black: self = .black
        case .sepia: self = .sepia
        }
    }

    /// The text colour, as in legacy `EpubReader.vue` `themeRules` (sepia from the web client).
    public var textColor: String {
        switch self {
        case .light: "#000"
        case .dark, .black: "#fff"
        case .sepia: "#5b4636"
        }
    }

    /// The page colour, as in legacy `EpubReader.vue` `themeRules` (sepia from the web client).
    public var backgroundColor: String {
        switch self {
        case .light: "rgb(255, 255, 255)"
        case .dark: "rgb(35 35 35)"
        case .black: "rgb(0 0 0)"
        case .sepia: "rgb(244, 236, 216)"
        }
    }

    /// The epub.js theme rules (`rendition.themes.register('abs', rules)`) for `settings`, a
    /// port of legacy `EpubReader.vue` `themeRules`: every element gets the theme's colours,
    /// line height and text stroke, and links get the text colour.
    ///
    /// The legacy reader set the font with `rendition.themes.font(…)`, which the bridge doesn't
    /// call, so `body` carries the same `font-family` override here. Font size isn't a rule:
    /// the bridge applies `fontScale` with `rendition.themes.fontSize`.
    public static func themeRules(
        for settings: ReaderSettings, resolvedAppearance: ReaderAppearance
    ) -> [String: [String: String]] {
        let theme = ReaderTheme(settings.theme, resolvedAppearance: resolvedAppearance)
        let color = theme.textColor
        return [
            "*": [
                "color": "\(color)!important",
                "background-color": "\(theme.backgroundColor)!important",
                "line-height": "\(settings.lineSpacing)%!important",
                "-webkit-text-stroke": "\(pixels(hundredths: settings.textStroke))px \(color)!important",
            ],
            "a": ["color": "\(color)!important"],
            "body": ["font-family": "\(settings.fontFamily.rawValue)!important"],
        ]
    }

    /// `value / 100` written as JavaScript would (`5` is `0.05`, `150` is `1.5`, `100` is `1`).
    static func pixels(hundredths value: Int) -> String {
        let sign = value < 0 ? "-" : ""
        let magnitude = abs(value)
        let whole = magnitude / 100
        let fraction = magnitude % 100
        guard fraction != 0 else { return "\(sign)\(whole)" }
        let digits = fraction < 10 ? "0\(fraction)" : "\(fraction)"
        return "\(sign)\(whole).\(digits.hasSuffix("0") ? String(digits.dropLast()) : digits)"
    }
}

/// The reader settings sent to the EPUB page with `open` and `applySettings`. This is the
/// bridge contract's `ReaderSettingsPayload`:
/// - the theme, already resolved;
/// - the numbers as stored;
/// - the column `gap` in CSS pixels (`0` is epub.js's default; the Duo hinge width when spanned);
/// - the precomputed ``ReaderTheme/themeRules(for:resolvedAppearance:)``.
public struct ReaderSettingsPayload: Sendable, Hashable, Encodable {
    public let theme: ReaderTheme
    public let fontFamily: ReaderSettings.FontFamily
    public let fontScale: Int
    public let lineSpacing: Int
    public let textStroke: Int
    public let spread: ReaderSettings.Spread
    public let gap: Double
    public let themeRules: [String: [String: String]]

    /// - Parameter gap: the column gap in CSS pixels; negative or non-finite values are `0`.
    public init(settings: ReaderSettings, resolvedAppearance: ReaderAppearance, gap: Double = 0) {
        theme = ReaderTheme(settings.theme, resolvedAppearance: resolvedAppearance)
        fontFamily = settings.fontFamily
        fontScale = settings.fontScale
        lineSpacing = settings.lineSpacing
        textStroke = settings.textStroke
        spread = settings.spread
        self.gap = gap.isFinite ? max(gap, 0) : 0
        themeRules = ReaderTheme.themeRules(for: settings, resolvedAppearance: resolvedAppearance)
    }
}
