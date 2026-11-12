import Foundation

/// The ebook reader's appearance settings (ADR 0008 decision 6), shared by every book. They
/// follow the legacy reader (`components/readers/Reader.vue` `ereaderSettings`), plus a sepia
/// theme and a "match system" default. A comic's reading direction is per item (decision 7),
/// so it isn't here.
///
/// Numbers are percentages on the legacy sliders' ranges and steps; out-of-range or off-step
/// values are clamped to the nearest allowed value, both when assigned and when decoded.
/// Decoding is lenient: a missing or unreadable field is its default, so stored settings from
/// an older or newer version still load.
public struct ReaderSettings: Sendable, Hashable, Codable {
    public enum Theme: String, CaseIterable, Sendable, Codable {
        /// Light or dark, following the system appearance.
        case matchSystem = "system"
        case light
        case dark
        case black
        case sepia
    }

    /// The raw values are the CSS generic families epub.js applies.
    public enum FontFamily: String, CaseIterable, Sendable, Codable {
        case serif
        case sansSerif = "sans-serif"
    }

    /// The `spread` setting, as epub.js, the legacy app and the EPUB bridge spell it: `auto` shows
    /// two pages when the layout is wide enough, `none` always one page. PDF, EPUB and comics
    /// share it through ABSAppModel's `ReaderSpreadPolicy` (ADR 0008 decision 7).
    public enum Spread: String, CaseIterable, Sendable, Codable {
        case auto
        case none
    }

    /// A slider's allowed values: `range` in steps of `step` from its lower bound.
    public struct Scale: Sendable, Hashable {
        public let range: ClosedRange<Int>
        public let step: Int
        public let defaultValue: Int

        /// The allowed value nearest to `value`.
        public func clamp(_ value: Int) -> Int {
            let bounded = min(max(value, range.lowerBound), range.upperBound)
            let offset = bounded - range.lowerBound
            let snapped = range.lowerBound + (offset + step / 2) / step * step
            return min(snapped, range.upperBound)
        }
    }

    /// Font size, percent (legacy 5...300 step 5, default 100).
    public static let fontScaleScale = Scale(range: 5...300, step: 5, defaultValue: 100)
    /// Line height, percent (legacy 100...300 step 5, default 115).
    public static let lineSpacingScale = Scale(range: 100...300, step: 5, defaultValue: 115)
    /// Text stroke ("font boldness"), hundredths of a pixel (legacy 0...300 step 5, default 0).
    public static let textStrokeScale = Scale(range: 0...300, step: 5, defaultValue: 0)

    public var theme: Theme
    public var fontFamily: FontFamily
    public var fontScale: Int { didSet { fontScale = Self.fontScaleScale.clamp(fontScale) } }
    public var lineSpacing: Int { didSet { lineSpacing = Self.lineSpacingScale.clamp(lineSpacing) } }
    public var textStroke: Int { didSet { textStroke = Self.textStrokeScale.clamp(textStroke) } }
    public var spread: Spread

    public init(
        theme: Theme = .matchSystem, fontFamily: FontFamily = .serif,
        fontScale: Int = ReaderSettings.fontScaleScale.defaultValue,
        lineSpacing: Int = ReaderSettings.lineSpacingScale.defaultValue,
        textStroke: Int = ReaderSettings.textStrokeScale.defaultValue, spread: Spread = .auto
    ) {
        self.theme = theme
        self.fontFamily = fontFamily
        self.fontScale = Self.fontScaleScale.clamp(fontScale)
        self.lineSpacing = Self.lineSpacingScale.clamp(lineSpacing)
        self.textStroke = Self.textStrokeScale.clamp(textStroke)
        self.spread = spread
    }

    private enum CodingKeys: String, CodingKey {
        case theme, fontFamily, fontScale, lineSpacing, textStroke, spread
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<Value: Decodable>(_ key: CodingKeys) -> Value? {
            (try? container.decodeIfPresent(Value.self, forKey: key)) ?? nil
        }
        let defaults = ReaderSettings()
        self.init(
            theme: value(.theme) ?? defaults.theme, fontFamily: value(.fontFamily) ?? defaults.fontFamily,
            fontScale: value(.fontScale) ?? defaults.fontScale,
            lineSpacing: value(.lineSpacing) ?? defaults.lineSpacing,
            textStroke: value(.textStroke) ?? defaults.textStroke, spread: value(.spread) ?? defaults.spread)
    }
}
