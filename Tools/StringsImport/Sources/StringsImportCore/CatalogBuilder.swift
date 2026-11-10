import Foundation

/// One `strings/<name>.json` file.
public struct LocaleFile: Sendable, Equatable {
    /// The file name without `.json`, e.g. `en-us`.
    public var name: String
    public var strings: [String: String]

    public init(name: String, strings: [String: String]) {
        self.name = name
        self.strings = strings
    }

    /// Loads every `*.json` file in `directory`, sorted by name.
    public static func load(directory: URL) throws -> [LocaleFile] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.map { url in
            let name = url.deletingPathExtension().lastPathComponent
            do {
                let strings = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
                return LocaleFile(name: name, strings: strings)
            } catch {
                throw ImportError.invalidFile(fileName: name, reason: "\(error)")
            }
        }
    }
}

/// The generated catalog and what went into it.
public struct CatalogBuildResult: Sendable {
    /// The `.xcstrings` file contents.
    public var json: String
    /// Apple identifiers with at least one string, source language first, then sorted.
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
        var seenLocales: Set<String> = []
        var locales: Set<String> = []

        for file in files {
            let locale = try LocaleMapping.appleIdentifier(forFileName: file.name)
            guard seenLocales.insert(locale).inserted else { throw .duplicateLocale(identifier: locale) }
            let isSource = file.name == sourceFileName
            for (key, value) in file.strings {
                guard let sourceValue = source[key] else {
                    warnings.append("\(file.name): skipped \(key): not in \(sourceFileName).json")
                    continue
                }
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if !isSource, let problem = StringConverter.problem(translation: value, source: sourceValue) {
                    warnings.append("\(file.name): skipped \(key): \(problem)")
                    continue
                }
                let isFormat = !StringConverter.placeholderIndices(in: sourceValue).isEmpty
                let converted = StringConverter.convert(value, isFormat: isFormat)
                for tag in StringConverter.unsupportedMarkup(in: converted) {
                    warnings.append("\(file.name): \(key) keeps unsupported markup \(tag)")
                }
                entries[key]?.localizations[locale] = Localization(stringUnit: StringUnit(value: converted))
                locales.insert(locale)
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
        let others = locales.subtracting([sourceLanguage]).sorted()
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

private struct Localization: Encodable {
    var stringUnit: StringUnit
}

private struct StringUnit: Encodable {
    var state = "translated"
    var value: String
}
