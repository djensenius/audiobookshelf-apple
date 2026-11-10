import Foundation

/// Converts legacy Vue i18n values to String Catalog values.
public enum StringConverter {
    /// The zero-based indices of `{N}` placeholders in `value`.
    public static func placeholderIndices(in value: String) -> Set<Int> {
        Set(value.matches(of: /\{(\d+)\}/).compactMap { Int($0.output.1) })
    }

    /// Converts a value:
    /// - `{N}` becomes the positional format specifier `%<N+1>$@`;
    /// - `<strong>x</strong>` and `<b>x</b>` become Markdown `**x**`;
    /// - `<br>` becomes a newline.
    ///
    /// When `isFormat` is true, a literal `%` is escaped as `%%`, as Xcode does for strings
    /// with arguments. Strings without arguments are not run through a formatter, so their
    /// `%` stays as is.
    public static func convert(_ value: String, isFormat: Bool) -> String {
        var result = isFormat ? value.replacing("%", with: "%%") : value
        result = result.replacing(/\{(\d+)\}/) { match in
            guard let index = Int(match.output.1) else { return String(match.output.0) }
            return "%\(index + 1)$@"
        }
        result = result.replacing(/(?i)<br\s*\/?>/, with: "\n")
        result = result.replacing(/(?is)<(strong|b)>(.*?)<\/\1>/) { match in
            bold(String(match.output.2))
        }
        return result
    }

    /// HTML-like tags left in `value` after conversion.
    public static func unsupportedMarkup(in value: String) -> [String] {
        value.matches(of: /<\/?[A-Za-z][^>]*>/).map { String($0.output) }
    }

    /// Why a translation can't be used with `source`, or `nil` when it can.
    ///
    /// A translation must not reference a placeholder the source lacks (the caller passes
    /// no argument for it) and must not contain a malformed placeholder such as `{0`.
    public static func problem(translation: String, source: String) -> String? {
        let extra = placeholderIndices(in: translation).subtracting(placeholderIndices(in: source))
        if !extra.isEmpty {
            let list = extra.sorted().map { "{\($0)}" }.joined(separator: ", ")
            return "uses \(list), which the source string does not have"
        }
        if translation.replacing(/\{\d+\}/, with: "").contains(/\{\d/) {
            return "has a malformed placeholder"
        }
        return nil
    }

    /// Markdown bold, with surrounding whitespace moved outside the delimiters.
    private static func bold(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        let leading = text.prefix { $0.isWhitespace }
        let trailing = String(text.reversed().prefix { $0.isWhitespace }.reversed())
        return "\(leading)**\(trimmed)**\(trailing)"
    }
}
