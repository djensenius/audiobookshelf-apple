import Foundation

/// The `import-strings` command:
/// `import-strings [--check] [--root <repository root>] [--baseline-base <git ref>]`.
///
/// Reads `strings/*.json` and `Localization/native/*.json` under the root, writes ABSUI's
/// `Localizable.xcstrings`, and verifies the app's `CFBundleLocalizations`. With `--check`
/// it writes nothing and fails if either is out of date. Both modes also check the Swift
/// sources (``SourceScanner``): they fail on a key missing from `en-us.json` or a hard-coded
/// user-facing string in `Features/` or ABSUI that ``HardCodedBaseline`` doesn't list (or an
/// entry there that no longer matches, or that the `--baseline-base` ref's baseline doesn't have;
/// see ``HardCodedBaseline/baseRef(environment:)`` for the default), and warn about keys no
/// longer used.
public enum ImportCommand {
    public static let catalogPath = "Packages/AudiobookshelfKit/Sources/ABSUI/Resources/Localizable.xcstrings"
    public static let infoPlistPath = "Audiobookshelf/Info.plist"
    public static let legacyPath = "strings"
    public static let nativePath = "Localization/native"

    /// Runs the command and returns the process exit status.
    public static func run(arguments: [String], root defaultRoot: URL, log: (String) -> Void = { print($0) }) -> Int32 {
        var check = false
        var root = defaultRoot
        var baseRef = HardCodedBaseline.baseRef(environment: ProcessInfo.processInfo.environment)
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--check":
                check = true
            case "--root":
                guard let path = remaining.popFirst() else {
                    log("error: --root needs a path")
                    return 1
                }
                root = URL(filePath: path)
            case "--baseline-base":
                guard let ref = remaining.popFirst() else {
                    log("error: --baseline-base needs a git ref")
                    return 1
                }
                baseRef = ref
            default:
                log(
                    "error: unknown argument \(argument); "
                        + "usage: import-strings [--check] [--root <path>] [--baseline-base <ref>]")
                return 1
            }
        }

        let result: CatalogBuildResult
        let files: [LocaleFile]
        let native: [LocaleFile]
        do {
            native = try LocaleFile.load(directory: root.appending(path: nativePath))
            files = try LocaleFile.merging(
                legacy: LocaleFile.load(directory: root.appending(path: legacyPath)),
                native: native
            )
            result = try CatalogBuilder.build(files: files)
        } catch {
            log("error: \(error)")
            return 1
        }
        for warning in result.warnings {
            log("warning: \(warning)")
        }

        var outOfDate = false
        let catalogURL = root.appending(path: catalogPath)
        if (try? String(contentsOf: catalogURL, encoding: .utf8)) != result.json {
            if check {
                log("error: \(catalogPath) is out of date; run 'mise run strings'")
                outOfDate = true
            } else {
                do {
                    try result.json.write(to: catalogURL, atomically: true, encoding: .utf8)
                } catch {
                    log("error: could not write \(catalogPath): \(error)")
                    return 1
                }
                log("Wrote \(catalogPath)")
            }
        }

        // Info.plist is hand-edited (rewriting it would reformat the file), so only verify it.
        if declaredLocalizations(at: root.appending(path: infoPlistPath)) != result.locales {
            let items = result.locales.map { "\t\t<string>\($0)</string>" }.joined(separator: "\n")
            log(
                """
                error: CFBundleLocalizations in \(infoPlistPath) does not match the catalog's locales. Use:
                \t<key>CFBundleLocalizations</key>
                \t<array>
                \(items)
                \t</array>
                """
            )
            outOfDate = true
        }

        let sourceKeys = files.first { $0.name == CatalogBuilder.sourceFileName }?.keys ?? []
        let nativeKeys = native.first { $0.name == CatalogBuilder.sourceFileName }?.keys ?? []
        do {
            if try !checkSources(
                root: root, sourceKeys: sourceKeys, nativeKeys: nativeKeys, baseRef: baseRef, log: log)
            {
                outOfDate = true
            }
        } catch {
            log("error: could not scan the Swift sources: \(error)")
            return 1
        }

        if outOfDate {
            return 1
        }
        log("\(result.locales.count) locales: \(result.locales.joined(separator: " "))")
        return 0
    }

    /// Checks the Swift sources against the source language's keys (see ``SourceScanner``) and
    /// returns whether they pass: every key used from Swift must exist, and `Features/` must not
    /// hard-code user-facing strings. Keys no longer used are only warned about,
    /// because many legacy keys are kept for features not ported yet.
    static func checkSources(
        root: URL, sourceKeys: Set<String>, nativeKeys: Set<String>, baseRef: String, log: (String) -> Void
    ) throws -> Bool {
        var passed = true
        let sources = try SourceScanner.load(root: root, paths: SourceScanner.keyPaths)
        let (required, mentioned) = SourceScanner.keyReferences(in: sources)
        for reference in required where !sourceKeys.contains(reference.key) {
            log(
                "error: \(reference.path):\(reference.line): \(reference.key) is not in \(legacyPath)/en-us.json "
                    + "or \(nativePath)/en-us.json; add it to \(nativePath)/en-us.json "
                    + "(or mark the line \(SourceScanner.ignoreMarker) if it isn't a key)")
            passed = false
        }
        let unused = sourceKeys.subtracting(mentioned)
        for (keys, path) in [
            (unused.intersection(nativeKeys), nativePath), (unused.subtracting(nativeKeys), legacyPath),
        ]
        where !keys.isEmpty {
            log(
                "warning: keys in \(path)/en-us.json not used from Swift (\(keys.count)): "
                    + keys.sorted().joined(separator: ", "))
        }

        let hardCoded = sources.filter { SourceScanner.scansForHardCodedStrings($0.path) }
            .flatMap { SourceScanner.hardCodedStrings(in: $0, keys: sourceKeys) }
        let baseline = try HardCodedBaseline.load(root: root)
        let (new, stale) = baseline.match(hardCoded)
        for string in new {
            log(
                "error: \(string): hard-coded user-facing string; use an L10n key "
                    + "(or mark the line \(SourceScanner.ignoreMarker) if it isn't prose)")
            passed = false
        }
        for (line, entry) in stale {
            log(
                "error: \(HardCodedBaseline.path):\(line): \(entry.path): no longer hard-coded "
                    + "(or the line changed); remove the entry")
            passed = false
        }
        if let base = try HardCodedBaseline.load(root: root, ref: baseRef) {
            for (line, entry) in baseline.additions(over: base) {
                log(
                    "error: \(HardCodedBaseline.path):\(line): \(entry.path): not in \(baseRef)'s baseline; "
                        + "the baseline only shrinks, so localize the string instead of listing it")
                passed = false
            }
        } else {
            log(
                "warning: can't read \(HardCodedBaseline.path) at \(baseRef) (fetch it, or pass "
                    + "--baseline-base <ref>), so baseline additions weren't checked")
        }
        return passed
    }

    private static func declaredLocalizations(at url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleLocalizations"] as? [String]
    }
}
