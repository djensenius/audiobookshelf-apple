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
        ("Welcome, <strong>{0}</strong>", "Welcome, **%1$@**"),
        ("<strong>Important!</strong> Read this.", "**Important!** Read this."),
        ("<b>Bold</b> and <B>bold</B>", "**Bold** and **bold**"),
        ("A <strong> spaced </strong> word", "A  **spaced**  word"),
        ("Line<br>break<br/>and<br />more", "Line\nbreak\nand\nmore"),
    ])
    func convertsHTMLToMarkdown(input: String, expected: String) {
        #expect(StringConverter.convert(input, isFormat: true) == expected)
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
