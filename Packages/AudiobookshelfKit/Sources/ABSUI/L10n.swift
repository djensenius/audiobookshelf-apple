import Foundation

/// Strings from ABSUI's `Localizable.xcstrings`, which `mise run strings` generates from
/// `strings/*.json` and `Localization/native/*.json`. Keys are the legacy keys, e.g.
/// `ButtonCancel`. See `docs/localization.md`.
public enum L10n {
    static var bundle: Bundle { .module }
    private static let table = "Localizable"
    private static let english = Bundle.module.url(forResource: "en", withExtension: "lproj").flatMap(Bundle.init(url:))

    /// The plain string for `key`, with the legacy `{0}`, `{1}`, … placeholders replaced by
    /// `arguments` in order.
    ///
    /// `locale` picks the language; `nil` uses the app's preferred localization. The importer
    /// fills untranslated keys with English; if a lookup still returns the key itself, this
    /// falls back to the English table.
    ///
    /// Markup in the value (e.g. bold, written `^[**x**]()`) is dropped: the result is the
    /// plain text of ``attributed(_:_:locale:)``. Never parse this result as Markdown,
    /// because the arguments (often server data) would be parsed too.
    public static func string(_ key: String, _ arguments: String..., locale: Locale? = nil) -> String {
        let format = lookup(key, locale: locale)
        if format.contains(where: markupCharacters.contains), let rendered = render(format, arguments: arguments) {
            return String(rendered.characters)
        }
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: locale ?? .current, arguments: arguments)
    }

    /// The string for `key` with its inline Markdown rendered and line breaks kept.
    ///
    /// Only the localized format is parsed as Markdown; `arguments` are inserted afterwards
    /// as plain text with the attributes around their placeholder (e.g. bold), so they can't
    /// add links or formatting.
    public static func attributed(_ key: String, _ arguments: String..., locale: Locale? = nil) -> AttributedString {
        let format = lookup(key, locale: locale)
        if let rendered = render(format, arguments: arguments) {
            return rendered
        }
        guard !arguments.isEmpty else { return AttributedString(format) }
        return AttributedString(String(format: format, locale: locale ?? .current, arguments: arguments))
    }

    /// Characters that can start inline Markdown; values without any skip the parser.
    private static let markupCharacters: Set<Character> = ["*", "_", "`", "[", "]", "^", "\\", "~", "<", "&"]

    /// Parses `format` as inline Markdown and inserts `arguments` as plain text, or returns
    /// `nil` if the format isn't valid Markdown.
    private static func render(_ format: String, arguments: [String]) -> AttributedString? {
        var format = format
        // Each specifier becomes a private-use sentinel that Markdown leaves alone.
        var values: [String] = []
        if !arguments.isEmpty {
            format = format.replacing(/%(?:(\d+)\$)?@|%%/) { match in
                if match.output.0 == "%%" { return "%" }
                let index = match.output.1.flatMap { Int($0) }.map { $0 - 1 } ?? values.count
                values.append(arguments.indices.contains(index) ? arguments[index] : "")
                return "\u{E000}\(values.count - 1)\u{E001}"
            }
        }
        // Extended attributes: the importer writes bold as `^[**x**]()` (see docs/localization.md).
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        options.allowsExtendedAttributes = true
        guard let parsed = try? AttributedString(markdown: format, options: options) else { return nil }
        guard !values.isEmpty else { return parsed }
        // Rebuild run by run so inserted arguments are never scanned for sentinels again.
        var result = AttributedString()
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            var start = text.startIndex
            for match in text.matches(of: /\u{E000}(\d+)\u{E001}/) {
                let value = Int(match.output.1).flatMap { values.indices.contains($0) ? values[$0] : nil } ?? ""
                result += AttributedString(String(text[start..<match.range.lowerBound]), attributes: run.attributes)
                result += AttributedString(value, attributes: run.attributes)
                start = match.range.upperBound
            }
            result += AttributedString(String(text[start...]), attributes: run.attributes)
        }
        return result
    }

    /// The localized value without the English fallback; `key` itself when the table lacks it.
    static func localized(_ key: String, locale: Locale?) -> String {
        guard let locale else { return Bundle.module.localizedString(forKey: key, value: nil, table: table) }
        var resource = LocalizedStringResource(
            String.LocalizationValue(key),
            table: table,
            bundle: .atURL(Bundle.module.bundleURL)
        )
        resource.locale = locale
        return String(localized: resource)
    }

    private static func lookup(_ key: String, locale: Locale?) -> String {
        let value = localized(key, locale: locale)
        guard value == key, let english else { return value }
        return english.localizedString(forKey: key, value: nil, table: table)
    }
}
