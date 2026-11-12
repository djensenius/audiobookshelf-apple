import Foundation

/// One `strings/<name>.json` file.
public struct LocaleFile: Sendable, Equatable {
    /// The file name without `.json`, e.g. `en-us`.
    public var name: String
    public var strings: [String: String]
    /// Plural strings: a JSON object of CLDR plural categories (`one`, `other`, …) instead of a
    /// string, whose `{0}` is the count (see ``StringConverter/convertPlural(_:)``).
    public var plurals: [String: [String: String]]

    public init(name: String, strings: [String: String], plurals: [String: [String: String]] = [:]) {
        self.name = name
        self.strings = strings
        self.plurals = plurals
    }

    /// Every key, plural or not.
    var keys: Set<String> { Set(strings.keys).union(plurals.keys) }

    /// Loads every `*.json` file in `directory`, sorted by name. A missing directory has none.
    public static func load(directory: URL) throws -> [LocaleFile] {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.map { url in
            let name = url.deletingPathExtension().lastPathComponent
            do {
                let values = try JSONDecoder().decode([String: Value].self, from: Data(contentsOf: url))
                return LocaleFile(
                    name: name, strings: values.compactMapValues(\.string), plurals: values.compactMapValues(\.plural))
            } catch {
                throw ImportError.invalidFile(fileName: name, reason: "\(error)")
            }
        }
    }

    /// A file's value: a string, or a plural's forms by category.
    private enum Value: Decodable {
        case string(String)
        case plural([String: String])

        var string: String? {
            if case .string(let value) = self { value } else { nil }
        }

        var plural: [String: String]? {
            if case .plural(let forms) = self { forms } else { nil }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .string(value)
            } else {
                self = .plural(try container.decode([String: String].self))
            }
        }
    }

    /// Merges native-only files (`Localization/native/`) over the legacy `strings/` files by
    /// file name. Throws if a native key also exists in the legacy source file, so the
    /// upstream data never overrides or is overridden silently.
    public static func merging(legacy: [LocaleFile], native: [LocaleFile]) throws(ImportError) -> [LocaleFile] {
        let legacySource = legacy.first { $0.name == CatalogBuilder.sourceFileName }
        let legacyKeys = legacySource?.keys ?? []
        var merged = Dictionary(uniqueKeysWithValues: legacy.map { ($0.name, $0) })
        for file in native {
            if let key = file.keys.sorted().first(where: legacyKeys.contains) {
                throw .duplicateKey(key: key, fileName: file.name)
            }
            merged[file.name, default: LocaleFile(name: file.name, strings: [:])].strings
                .merge(file.strings) { _, new in new }
            merged[file.name, default: LocaleFile(name: file.name, strings: [:])].plurals
                .merge(file.plurals) { _, new in new }
        }
        return merged.values.sorted { $0.name < $1.name }
    }
}

/// The generated catalog and what went into it.
public struct CatalogBuildResult: Sendable {
    /// The `.xcstrings` file contents.
    public var json: String
    /// Apple identifiers with at least one translated string, source language first, then
    /// sorted. Each of them has every key: untranslated ones get the English value.
    public var locales: [String]
    /// Translations that were skipped or converted with leftovers, for the log.
    public var warnings: [String]
}

/// Builds a String Catalog from the legacy strings files.
public enum CatalogBuilder {
    public static let sourceFileName = "en-us"
    public static let sourceLanguage = "en"

    public static func build(files: [LocaleFile]) throws(ImportError) -> CatalogBuildResult {
        guard let sourceFile = files.first(where: { $0.name == sourceFileName }) else {
            throw .missingSource(fileName: sourceFileName)
        }
        let source = sourceFile.strings
        var warnings: [String] = []
        var entries = source.mapValues { _ in Entry(localizations: [:]) }
        for (key, forms) in sourceFile.plurals {
            if let problem = StringConverter.pluralProblem(forms) {
                throw .invalidFile(fileName: sourceFileName, reason: "\(key) \(problem)")
            }
            entries[key] = Entry(localizations: [:])
        }
        var seenLocales: Set<String> = []
        var locales: Set<String> = []

        for file in files {
            let locale = try LocaleMapping.appleIdentifier(forFileName: file.name)
            guard seenLocales.insert(locale).inserted else { throw .duplicateLocale(identifier: locale) }
            let isSource = file.name == sourceFileName
            for (key, forms) in file.plurals {
                guard let sourceForms = sourceFile.plurals[key] else {
                    warnings.append("\(file.name): skipped \(key): not a plural in \(sourceFileName).json")
                    continue
                }
                // A form may use the placeholders of the source's `other` form, which has them all.
                let sourceOther = sourceForms["other"] ?? ""
                let problem =
                    StringConverter.pluralProblem(forms)
                    ?? forms.keys.sorted().lazy
                    .compactMap { StringConverter.problem(translation: forms[$0] ?? "", source: sourceOther) }.first
                if !isSource, let problem {
                    warnings.append("\(file.name): skipped \(key): \(problem)")
                    continue
                }
                let plural = forms.mapValues {
                    Variant(stringUnit: StringUnit(value: StringConverter.convertPlural($0)))
                }
                entries[key]?.localizations[locale] = Localization(variations: Variations(plural: plural))
                locales.insert(locale)
            }
            for (key, value) in file.strings {
                if sourceFile.plurals[key] != nil {
                    warnings.append("\(file.name): skipped \(key): a plural in \(sourceFileName).json")
                    continue
                }
                guard let sourceValue = source[key] else {
                    warnings.append("\(file.name): skipped \(key): not in \(sourceFileName).json")
                    continue
                }
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if !isSource, let problem = StringConverter.problem(translation: value, source: sourceValue) {
                    warnings.append("\(file.name): skipped \(key): \(problem)")
                    continue
                }
                let sourcePlaceholders = StringConverter.placeholderIndices(in: sourceValue)
                let dropped = sourcePlaceholders.subtracting(StringConverter.placeholderIndices(in: value))
                if !isSource, !dropped.isEmpty {
                    let list = dropped.sorted().map { "{\($0)}" }.joined(separator: ", ")
                    warnings.append("\(file.name): \(key) drops \(list)")
                }
                let isFormat = !sourcePlaceholders.isEmpty
                let converted = StringConverter.convert(value, isFormat: isFormat)
                for tag in StringConverter.unsupportedMarkup(in: converted) {
                    warnings.append("\(file.name): \(key) keeps unsupported markup \(tag)")
                }
                entries[key]?.localizations[locale] = Localization(stringUnit: StringUnit(value: converted))
                locales.insert(locale)
            }
        }

        // A string a locale hasn't translated gets the English value marked "new". Without it
        // the compiled table returns the key name (Foundation doesn't fall back per key). A plural
        // gets none: Foundation would pick the English forms by the locale's plural rules ("1 books"
        // in Japanese), so `L10n.plural` falls back to English with English rules instead.
        let others = locales.subtracting([sourceLanguage]).sorted()
        for key in entries.keys where sourceFile.plurals[key] == nil {
            guard let english = entries[key]?.localizations[sourceLanguage]?.markedNew else { continue }
            for locale in others where entries[key]?.localizations[locale] == nil {
                entries[key]?.localizations[locale] = english
            }
        }

        let catalog = Catalog(sourceLanguage: sourceLanguage, strings: entries, version: "1.0")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(catalog)
        } catch {
            throw .invalidFile(fileName: sourceFileName, reason: "could not encode the catalog: \(error)")
        }
        return CatalogBuildResult(
            json: String(decoding: data, as: UTF8.self) + "\n",
            locales: [sourceLanguage] + others,
            warnings: warnings.sorted()
        )
    }
}

// The subset of the String Catalog schema the importer writes.
private struct Catalog: Encodable {
    var sourceLanguage: String
    var strings: [String: Entry]
    var version: String
}

private struct Entry: Encodable {
    var extractionState = "manual"
    var localizations: [String: Localization]
}

/// A string unit, or plural variations.
private struct Localization: Encodable {
    var stringUnit: StringUnit?
    var variations: Variations?

    init(stringUnit: StringUnit) {
        self.stringUnit = stringUnit
    }

    init(variations: Variations) {
        self.variations = variations
    }

    /// The same string in the "new" state, for a locale that hasn't translated it.
    var markedNew: Localization {
        var result = self
        result.stringUnit?.state = "new"
        return result
    }
}

private struct Variations: Encodable {
    var plural: [String: Variant]
}

private struct Variant: Encodable {
    var stringUnit: StringUnit
}

private struct StringUnit: Encodable {
    var state = "translated"
    var value: String
}
