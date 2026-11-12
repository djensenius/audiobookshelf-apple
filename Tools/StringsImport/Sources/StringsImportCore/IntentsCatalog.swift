import Foundation

/// The App Intents strings: `Localization/intents/*.json` to `AppIntents.xcstrings` in the shared
/// intents folder.
///
/// App Intents metadata (titles, parameters, dialogs) resolves its `LocalizedStringResource`s in
/// the bundle that declares the intent, the app or the widget extension, never in ABSUI's package
/// bundle, so these strings get their own table that both targets compile. Its keys start with
/// `Intent`.
public enum IntentsCatalog {
    public static let inputPath = "Localization/intents"
    public static let catalogPath = "AudiobookshelfShared/Intents/AppIntents.xcstrings"

    /// Writes the catalog, or with `check` verifies it, logging what it does.
    /// - Returns: `false` if the catalog is out of date (with `check`) or couldn't be built or
    ///   written. With no input directory there is nothing to do.
    public static func sync(root: URL, check: Bool, log: (String) -> Void) -> Bool {
        let input = root.appending(path: inputPath)
        guard FileManager.default.fileExists(atPath: input.path(percentEncoded: false)) else { return true }
        let result: CatalogBuildResult
        do {
            let files = try LocaleFile.load(directory: input)
            let keys = files.flatMap { Array($0.strings.keys) + Array($0.plurals.keys) }
            if let key = keys.sorted().first(where: { !$0.hasPrefix("Intent") }) {
                log("error: \(inputPath): \(key) must start with Intent")
                return false
            }
            result = try CatalogBuilder.build(files: files)
        } catch {
            log("error: \(inputPath): \(error)")
            return false
        }
        for warning in result.warnings {
            log("warning: \(inputPath): \(warning)")
        }

        let url = root.appending(path: catalogPath)
        guard (try? String(contentsOf: url, encoding: .utf8)) != result.json else { return true }
        if check {
            log("error: \(catalogPath) is out of date; run 'mise run strings'")
            return false
        }
        do {
            try result.json.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            log("error: could not write \(catalogPath): \(error)")
            return false
        }
        log("Wrote \(catalogPath)")
        return true
    }
}
