import Foundation

/// Maps `strings/<name>.json` file names to Apple localization identifiers.
public enum LocaleMapping {
    /// File names that differ from their Apple identifier.
    public static let overrides: [String: String] = [
        "en-us": "en",
        "no": "nb",
        "pt-br": "pt-BR",
        "vi-vn": "vi",
        "zh-cn": "zh-Hans",
        "zh_Hant": "zh-Hant",
    ]

    /// The Apple identifier for a strings file name (without `.json`).
    ///
    /// Throws when the result is not a canonical BCP 47 identifier with a known ISO
    /// language code, so a new Weblate file such as `pt-pt` needs an explicit mapping.
    public static func appleIdentifier(forFileName name: String) throws(ImportError) -> String {
        let identifier = overrides[name] ?? name
        let locale = Locale(identifier: identifier)
        guard let language = locale.language.languageCode,
            Locale.LanguageCode.isoLanguageCodes.contains(language),
            locale.identifier(.bcp47) == identifier
        else {
            throw .unknownLocale(fileName: name, identifier: identifier)
        }
        return identifier
    }
}
