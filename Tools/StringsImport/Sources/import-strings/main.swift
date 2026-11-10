import Foundation
import StringsImportCore

// Generates Packages/AudiobookshelfKit/Sources/ABSUI/Resources/Localizable.xcstrings from
// strings/*.json. Usage: import-strings [--check] [--root <repository root>]
// --check writes nothing and exits non-zero if the catalog or the app's
// CFBundleLocalizations are out of date.

let catalogPath = "Packages/AudiobookshelfKit/Sources/ABSUI/Resources/Localizable.xcstrings"
let infoPlistPath = "Audiobookshelf/Info.plist"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

var check = false
var root = URL(filePath: FileManager.default.currentDirectoryPath)
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--check":
        check = true
    case "--root":
        guard let path = arguments.popFirst() else { fail("--root needs a path") }
        root = URL(filePath: path)
    default:
        fail("unknown argument \(argument); usage: import-strings [--check] [--root <path>]")
    }
}

let result: CatalogBuildResult
do {
    result = try CatalogBuilder.build(files: LocaleFile.load(directory: root.appending(path: "strings")))
} catch {
    fail("\(error)")
}
for warning in result.warnings {
    print("warning: \(warning)")
}

var outOfDate = false
let catalogURL = root.appending(path: catalogPath)
let existing = try? String(contentsOf: catalogURL, encoding: .utf8)
if existing != result.json {
    if check {
        print("error: \(catalogPath) is out of date; run 'mise run strings'")
        outOfDate = true
    } else {
        do {
            try result.json.write(to: catalogURL, atomically: true, encoding: .utf8)
        } catch {
            fail("could not write \(catalogPath): \(error)")
        }
        print("Wrote \(catalogPath)")
    }
}

// Info.plist is hand-edited (rewriting it would reformat the file), so only verify it.
let plistData = try? Data(contentsOf: root.appending(path: infoPlistPath))
let plist = plistData.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
let declared = plist?["CFBundleLocalizations"] as? [String]
if declared != result.locales {
    let items = result.locales.map { "\t\t<string>\($0)</string>" }.joined(separator: "\n")
    print(
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

if outOfDate {
    exit(1)
}
print("\(result.locales.count) locales: \(result.locales.joined(separator: " "))")
