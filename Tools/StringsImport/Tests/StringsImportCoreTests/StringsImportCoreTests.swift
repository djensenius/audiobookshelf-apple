import Foundation
import StringsImportCore
import Testing

@Suite struct StringConverterTests {
    @Test(arguments: [
        ("by {0}", "by %1$@"),
        ("{0} episodes, {1} incomplete", "%1$@ episodes, %2$@ incomplete"),
        ("{1} before {0}", "%2$@ before %1$@"),
        ("{0} and {0}", "%1$@ and %1$@"),
        ("{10}", "%11$@"),
        ("No placeholders", "No placeholders"),
    ])
    func convertsPlaceholders(input: String, expected: String) {
        #expect(StringConverter.convert(input, isFormat: true) == expected)
    }

    @Test func escapesPercentOnlyInFormats() {
        #expect(StringConverter.convert("{0}% done", isFormat: true) == "%1$@%% done")
        #expect(StringConverter.convert("100%", isFormat: false) == "100%")
    }

    @Test(arguments: [
        ("Welcome, <strong>{0}</strong>", "Welcome, ^[**%1$@**]()"),
        ("<strong>Important!</strong> Read this.", "^[**Important!**]() Read this."),
        ("<b>Bold</b> and <B>bold</B>", "^[**Bold**]() and ^[**bold**]()"),
        ("A <strong> spaced </strong> word", "A  ^[**spaced**]()  word"),
        ("<strong>重要提示！</strong>此应用", "^[**重要提示！**]()此应用"),
        ("<strong>[a]</strong>", "^[**\\[a\\]**]()"),
        ("Line<br>break<br/>and<br />more", "Line\nbreak\nand\nmore"),
    ])
    func convertsHTMLToMarkdown(input: String, expected: String) {
        #expect(StringConverter.convert(input, isFormat: true) == expected)
    }

    /// Renders with the options `L10n.attributed` uses.
    @Test(arguments: [
        ("<strong>重要提示！</strong>此应用旨在", "重要提示！", "此应用旨在"),
        ("<strong>重要！</strong>此應用程式", "重要！", "此應用程式"),
        ("<strong>Important!</strong> This app", "Important!", " This app"),
        ("<strong>[a]</strong>b", "[a]", "b"),
    ])
    func boldRendersAtAnyBoundary(input: String, bold: String, rest: String) throws {
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        options.allowsExtendedAttributes = true
        let rendered = try AttributedString(
            markdown: StringConverter.convert(input, isFormat: false),
            options: options
        )
        #expect(String(rendered.characters) == bold + rest)
        let runs = rendered.runs.map { (String(rendered[$0.range].characters), $0.inlinePresentationIntent) }
        #expect(runs.count == 2)
        #expect(runs.first?.0 == bold)
        #expect(runs.first?.1 == .stronglyEmphasized)
        #expect(runs.last?.1 == nil)
    }

    @Test func reportsUnsupportedMarkup() {
        let converted = StringConverter.convert("<i>x</i> <strong>y</strong>", isFormat: false)
        #expect(StringConverter.unsupportedMarkup(in: converted) == ["<i>", "</i>"])
    }

    @Test func findsPlaceholderProblems() {
        #expect(StringConverter.problem(translation: "Lisätty {0}", source: "Added {0}") == nil)
        #expect(StringConverter.problem(translation: "Lisätty", source: "Added {0}") == nil)
        #expect(StringConverter.problem(translation: "Pridėta {0}", source: "Added At") != nil)
        #expect(StringConverter.problem(translation: "Tervetuloa, <strong>{0</strong>", source: "Welcome, {0}") != nil)
    }
}

@Suite struct LocaleMappingTests {
    @Test(arguments: [
        ("en-us", "en"),
        ("pt-br", "pt-BR"),
        ("zh-cn", "zh-Hans"),
        ("zh_Hant", "zh-Hant"),
        ("vi-vn", "vi"),
        ("no", "nb"),
        ("de", "de"),
        ("fr", "fr"),
    ])
    func mapsFileNames(fileName: String, identifier: String) throws {
        #expect(try LocaleMapping.appleIdentifier(forFileName: fileName) == identifier)
    }

    @Test(arguments: ["pt-pt", "xx", "en_US", "zh-hans"])
    func rejectsNonCanonicalIdentifiers(fileName: String) {
        #expect(throws: ImportError.self) { try LocaleMapping.appleIdentifier(forFileName: fileName) }
    }

    @Test func mapsEveryRepositoryStringsFile() throws {
        let directory = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "strings")
        let files = try LocaleFile.load(directory: directory)
        #expect(files.count > 40)
        for file in files {
            #expect(throws: Never.self) { try LocaleMapping.appleIdentifier(forFileName: file.name) }
        }
    }
}

@Suite struct CatalogBuilderTests {
    let files = [
        LocaleFile(
            name: "en-us", strings: ["ButtonCancel": "Cancel", "LabelByAuthor": "by {0}", "LabelAddedAt": "Added At"]),
        LocaleFile(name: "de", strings: ["ButtonCancel": "Abbrechen", "LabelByAuthor": "von {0}", "LabelAddedAt": ""]),
        LocaleFile(name: "lt", strings: ["LabelAddedAt": "Pridėta {0}"]),
        LocaleFile(name: "lv", strings: [:]),
    ]

    @Test func encodesCatalogLikeXcode() throws {
        let result = try CatalogBuilder.build(files: files)
        let expected = """
            {
              "sourceLanguage" : "en",
              "strings" : {
                "ButtonCancel" : {
                  "extractionState" : "manual",
                  "localizations" : {
                    "de" : {
                      "stringUnit" : {
                        "state" : "translated",
                        "value" : "Abbrechen"
                      }
                    },
                    "en" : {
                      "stringUnit" : {
                        "state" : "translated",
                        "value" : "Cancel"
                      }
                    }
                  }
                },
                "LabelAddedAt" : {
                  "extractionState" : "manual",
                  "localizations" : {
                    "de" : {
                      "stringUnit" : {
                        "state" : "new",
                        "value" : "Added At"
                      }
                    },
                    "en" : {
                      "stringUnit" : {
                        "state" : "translated",
                        "value" : "Added At"
                      }
                    }
                  }
                },
                "LabelByAuthor" : {
                  "extractionState" : "manual",
                  "localizations" : {
                    "de" : {
                      "stringUnit" : {
                        "state" : "translated",
                        "value" : "von %1$@"
                      }
                    },
                    "en" : {
                      "stringUnit" : {
                        "state" : "translated",
                        "value" : "by %1$@"
                      }
                    }
                  }
                }
              },
              "version" : "1.0"
            }

            """
        #expect(result.json == expected)
    }

    @Test func listsLocalesWithStringsSourceFirst() throws {
        let result = try CatalogBuilder.build(files: files)
        #expect(result.locales == ["en", "de"])
    }

    @Test func fillsUntranslatedKeysWithEnglishMarkedNew() throws {
        let files = [
            LocaleFile(
                name: "en-us", strings: ["ButtonCancel": "Cancel", "HeaderWelcome": "Welcome, {0}", "Empty": "E"]),
            LocaleFile(
                name: "fi", strings: ["ButtonCancel": "Peruuta", "HeaderWelcome": "Tervetuloa, {0", "Empty": " "]),
        ]
        let json = try CatalogBuilder.build(files: files).json
        let catalog = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: [String: Any]])
        func unit(_ key: String, _ locale: String) -> [String: String]? {
            let localizations = strings[key]?["localizations"] as? [String: [String: [String: String]]]
            return localizations?[locale]?["stringUnit"]
        }
        #expect(unit("ButtonCancel", "fi") == ["state": "translated", "value": "Peruuta"])
        // Skipped (malformed) and empty translations both fall back to English.
        #expect(unit("HeaderWelcome", "fi") == ["state": "new", "value": "Welcome, %1$@"])
        #expect(unit("Empty", "fi") == ["state": "new", "value": "E"])
        #expect(unit("Empty", "en") == ["state": "translated", "value": "E"])
    }

    @Test func warnsAboutSkippedTranslations() throws {
        let result = try CatalogBuilder.build(files: files)
        #expect(result.warnings == ["lt: skipped LabelAddedAt: uses {0}, which the source string does not have"])
    }

    @Test func isDeterministic() throws {
        let first = try CatalogBuilder.build(files: files)
        let second = try CatalogBuilder.build(files: files.reversed())
        #expect(first.json == second.json)
    }

    @Test func requiresSourceFile() {
        #expect(throws: ImportError.missingSource(fileName: "en-us")) {
            try CatalogBuilder.build(files: [LocaleFile(name: "de", strings: [:])])
        }
    }

    @Test func rejectsDuplicateLocales() {
        let duplicate = files + [LocaleFile(name: "nb", strings: [:]), LocaleFile(name: "no", strings: [:])]
        #expect(throws: ImportError.duplicateLocale(identifier: "nb")) { try CatalogBuilder.build(files: duplicate) }
    }
}

@Suite struct DroppedPlaceholderTests {
    @Test func warnsButKeepsTranslationThatUsesOnlyLaterPlaceholder() throws {
        let files = [
            LocaleFile(name: "en-us", strings: ["LabelPair": "{0} of {1}"]),
            LocaleFile(name: "de", strings: ["LabelPair": "nur {1}"]),
        ]
        let result = try CatalogBuilder.build(files: files)
        #expect(result.warnings == ["de: LabelPair drops {0}"])
        #expect(result.json.contains(#""value" : "nur %2$@""#))
    }

    @Test func literalPercentNextToPlaceholderFormatsAsPercent() {
        let converted = StringConverter.convert("{0}% done", isFormat: true)
        #expect(converted == "%1$@%% done")
        #expect(String(format: converted, "50") == "50% done")
    }
}

@Suite struct NativeMergeTests {
    let legacy = [
        LocaleFile(name: "de", strings: ["ButtonCancel": "Abbrechen"]),
        LocaleFile(name: "en-us", strings: ["ButtonCancel": "Cancel"]),
    ]

    @Test func mergesNativeKeysAndFillsUntranslatedOnes() throws {
        let native = [LocaleFile(name: "en-us", strings: ["NativeOnly": "Native"])]
        let merged = try LocaleFile.merging(legacy: legacy, native: native)
        #expect(merged.map(\.name) == ["de", "en-us"])
        #expect(merged[1].strings == ["ButtonCancel": "Cancel", "NativeOnly": "Native"])
        let json = try CatalogBuilder.build(files: merged).json
        #expect(json.contains(#""state" : "new",\#n            "value" : "Native""#))
    }

    @Test func addsNativeTranslationFiles() throws {
        let native = [
            LocaleFile(name: "en-us", strings: ["NativeOnly": "Native"]),
            LocaleFile(name: "fr", strings: ["NativeOnly": "Natif"]),
        ]
        let merged = try LocaleFile.merging(legacy: legacy, native: native)
        #expect(merged.map(\.name) == ["de", "en-us", "fr"])
        #expect(merged[2].strings == ["NativeOnly": "Natif"])
    }

    @Test func rejectsKeysThatExistInBoth() {
        let native = [LocaleFile(name: "de", strings: ["ButtonCancel": "Abbruch"])]
        #expect(throws: ImportError.duplicateKey(key: "ButtonCancel", fileName: "de")) {
            try LocaleFile.merging(legacy: legacy, native: native)
        }
    }
}

@Suite struct ImportCommandTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "StringsImportTests-\(UUID().uuidString)")
        try write(#"{"ButtonCancel": "Cancel"}"#, to: "strings/en-us.json")
        try write(#"{"ButtonCancel": "Abbrechen"}"#, to: "strings/de.json")
        try write("{}", to: "Localization/native/en-us.json")
        try write(plist(["en", "de"]), to: ImportCommand.infoPlistPath)
        try FileManager.default.createDirectory(
            at: root.appending(path: ImportCommand.catalogPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func write(_ text: String, to path: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func plist(_ locales: [String]) -> String {
        let items = locales.map { "<string>\($0)</string>" }.joined()
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>CFBundleLocalizations</key><array>\(items)</array></dict></plist>
            """
    }

    func run(_ arguments: String...) -> (status: Int32, log: [String]) {
        var log: [String] = []
        let status = ImportCommand.run(arguments: arguments + ["--root", root.path()], root: root) { log.append($0) }
        return (status, log)
    }

    @Test func checkFailsUntilCatalogIsWritten() {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(run("--check").status == 1)
        #expect(run().status == 0)
        #expect(run().status == 0)
        #expect(run("--check").status == 0)
    }

    @Test func infoPlistMismatchFailsBothModes() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write(plist(["en"]), to: ImportCommand.infoPlistPath)
        let written = run()
        #expect(written.status == 1)
        #expect(written.log.contains { $0.contains("CFBundleLocalizations") && $0.contains("<string>de</string>") })
        #expect(run("--check").status == 1)
    }

    @Test func rejectsUnknownArguments() {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(run("--bogus").status == 1)
    }
}
