import Foundation
import StringsImportCore

// Generates ABSUI's Localizable.xcstrings from strings/*.json and Localization/native/*.json.
// Usage: import-strings [--check] [--root <repository root>]. See docs/localization.md.
exit(
    ImportCommand.run(
        arguments: Array(CommandLine.arguments.dropFirst()),
        root: URL(filePath: FileManager.default.currentDirectoryPath)
    )
)
