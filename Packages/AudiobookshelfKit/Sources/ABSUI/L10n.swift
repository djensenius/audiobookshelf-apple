import Foundation

/// Strings from ABSUI's `Localizable.xcstrings`, which `mise run strings` generates from
/// `strings/*.json`. Keys are the legacy keys, e.g. `ButtonCancel`. See
/// `docs/localization.md`.
public enum L10n {
    private static let table = "Localizable"
    private static let english = Bundle.module.url(forResource: "en", withExtension: "lproj").flatMap(Bundle.init(url:))

    /// The string for `key`, with the legacy `{0}`, `{1}`, … placeholders replaced by
    /// `arguments` in order.
    ///
    /// `locale` picks the language; `nil` uses the app's preferred localization. A key a
    /// language hasn't translated yet falls back to English: the compiled tables return the
    /// key itself for those, not the source string.
    ///
    /// Values may contain Markdown such as `**bold**`; render it with
    /// `AttributedString(markdown:)`.
    public static func string(_ key: String, _ arguments: String..., locale: Locale? = nil) -> String {
        let format = lookup(key, locale: locale)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: locale ?? .current, arguments: arguments)
    }

    private static func lookup(_ key: String, locale: Locale?) -> String {
        let value: String
        if let locale {
            var resource = LocalizedStringResource(
                String.LocalizationValue(key),
                table: table,
                bundle: .atURL(Bundle.module.bundleURL)
            )
            resource.locale = locale
            value = String(localized: resource)
        } else {
            value = Bundle.module.localizedString(forKey: key, value: nil, table: table)
        }
        guard value == key, let english else { return value }
        return english.localizedString(forKey: key, value: nil, table: table)
    }
}
