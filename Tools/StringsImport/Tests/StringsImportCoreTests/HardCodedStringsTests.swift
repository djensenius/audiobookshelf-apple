import Foundation
import StringsImportCore
import Testing

@Suite struct HardCodedScopeTests {
    func lines(_ text: String, path: String = "Audiobookshelf/Features/A/A.swift") -> [Int] {
        SourceScanner.hardCodedStrings(in: .init(path: path, text: text), keys: []).map(\.line)
    }

    @Test func scansFeaturesAndABSUIOnly() {
        #expect(SourceScanner.scansForHardCodedStrings("Audiobookshelf/Features/A/A.swift"))
        #expect(SourceScanner.scansForHardCodedStrings("Packages/AudiobookshelfKit/Sources/ABSUI/Items/Row.swift"))
        #expect(!SourceScanner.scansForHardCodedStrings("Audiobookshelf/Shell/Root.swift"))
        #expect(!SourceScanner.scansForHardCodedStrings("Packages/AudiobookshelfKit/Sources/ABSUIX/Row.swift"))
        #expect(!SourceScanner.scansForHardCodedStrings("Packages/AudiobookshelfKit/Sources/ABSAPI/Client.swift"))
    }

    /// `#Preview` bodies are skipped to their closing brace; the code after them isn't. A brace in
    /// a string or comment doesn't end one early.
    @Test func skipsPreviews() {
        let text = """
            #Preview("Row") {
                Text("Hello")
                Text(verbatim: "}")  // }
                VStack {
                    Text("Nested")
                }
            }
            Text("After")
            #Preview { Text("One line") }
            Text("After one line")
            #Preview("Split")
            {
                Text("Split body")
            }
            Text("After split")
            """
        #expect(lines(text) == [8, 10, 15])
    }

    @Test func skipsPreviewProviders() {
        let text = """
            struct Row_Previews: PreviewProvider {
                static var previews: some View {
                    Text("Hello")
                }
            }
            Text("After")
            """
        #expect(lines(text) == [6])
    }

    /// Only the `#if DEBUG` branch is skipped, nested conditionals included; `#else` code and
    /// `#if !DEBUG` code are checked.
    @Test func skipsDebugCode() {
        let text = """
            #if DEBUG
            Text("Debug")
            #if os(iOS)
            Text("Debug iOS")
            #endif
            Text("Debug again")
            #else
            Text("Release")
            #endif
            #if os(iOS)
            Text("iOS")
            #elseif DEBUG
            Text("Not handled: elseif")
            #endif
            #if !DEBUG
            Text("Not debug")
            #endif
            Text("After")
            """
        #expect(lines(text) == [8, 11, 13, 16, 18])
    }

    /// A `#Preview` or `#if DEBUG` in a string or comment isn't one.
    @Test func ignoresDirectivesInStringsAndComments() {
        let text = """
            let a = "#Preview {"
            // #if DEBUG
            Text("Shown")
            let b = "PreviewProvider {"
            Text("Shown too")
            """
        #expect(lines(text) == [3, 5])
    }
}

@Suite struct HardCodedBaselineTests {
    let features = "Audiobookshelf/Features/A/A.swift"

    func strings(_ text: String) -> [SourceScanner.HardCodedString] {
        SourceScanner.hardCodedStrings(in: .init(path: features, text: text), keys: [])
    }

    @Test func recordsTheTrimmedSource() {
        #expect(strings("    Text(\"Hello\")  ").map(\.code) == [#"Text("Hello")"#])
    }

    @Test func parsesEntriesAndRejectsMalformedLines() throws {
        let baseline = try HardCodedBaseline(text: "# A comment\n\n\(features)\tText(\"Hello\")  \n")
        #expect(baseline.entries.map(\.line) == [3])
        #expect(baseline.entries.map(\.entry) == [.init(path: features, code: #"Text("Hello")"#)])
        #expect(throws: ImportError.invalidBaselineLine(line: 2)) {
            try HardCodedBaseline(text: "# A comment\n\(features) Text(\"Hello\")")
        }
        #expect(throws: ImportError.invalidBaselineLine(line: 1)) { try HardCodedBaseline(text: "\(features)\t ") }
    }

    /// An entry accepts one string with its file and source, wherever it moved in the file; the
    /// rest are new, and entries left over are stale.
    @Test func matchesByFileAndSourceOnce() throws {
        let found = strings("\nText(\"Hello\")\nText(\"Hello\")\nText(\"Bye\")")
        #expect(found.map(\.line) == [2, 3, 4])
        let baseline = try HardCodedBaseline(
            text: """
                \(features)\tText("Hello")
                Audiobookshelf/Features/B/B.swift\tText("Bye")
                \(features)\tText("Gone")
                """)
        let (new, stale) = baseline.match(found)
        #expect(new.map(\.line) == [3, 4])
        #expect(stale.map(\.line) == [2, 3])
        // Negative control: no baseline accepts nothing and has nothing stale.
        let empty = try HardCodedBaseline(text: "").match(found)
        #expect(empty.new == found)
        #expect(empty.stale.isEmpty)
    }
}

@Suite struct HardCodedCheckTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "HardCodedCheckTests-\(UUID().uuidString)")
        try write(#"{"ButtonCancel": "Cancel"}"#, to: "strings/en-us.json")
        try write(#"{"ButtonCancel": "Abbrechen"}"#, to: "strings/de.json")
        try write("{}", to: "Localization/native/en-us.json")
        try write(plist(["en", "de"]), to: ImportCommand.infoPlistPath)
        try FileManager.default.createDirectory(
            at: root.appending(path: ImportCommand.catalogPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
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

    func errors(_ log: [String]) -> [String] { log.filter { $0.hasPrefix("error:") } }

    /// A hard-coded `Text("Hello")` in ABSUI fails until the baseline lists it; localized and
    /// verbatim non-literal text passes.
    @Test func newStringsFailAndBaselinedOnesPass() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "Packages/AudiobookshelfKit/Sources/ABSUI/Rows/Row.swift"
        try write(
            """
            Text(L10n.string("ButtonCancel"))
            Text(verbatim: title)
            #Preview { Text("Preview") }
            """, to: path)
        #expect(run().status == 0)
        #expect(run("--check").status == 0)

        try write("\n    Text(\"Hello\")", to: path)
        let checked = run("--check")
        #expect(checked.status == 1)
        #expect(
            errors(checked.log).map { String($0.prefix { $0 != ";" }) } == [
                #"error: Packages/AudiobookshelfKit/Sources/ABSUI/Rows/Row.swift:2: "Hello": hard-coded user-facing string"#
            ])

        try write("# Accepted for now\n\(path)\tText(\"Hello\")\n", to: HardCodedBaseline.path)
        #expect(run("--check").status == 0)
        // Moving the line keeps the entry.
        try write("\n\n\n        Text(\"Hello\")", to: path)
        #expect(run("--check").status == 0)
    }

    /// An entry whose string was localized fails, so the baseline only shrinks.
    @Test func staleEntriesFail() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "Audiobookshelf/Features/A/A.swift"
        try write(#"Text(L10n.string("ButtonCancel"))"#, to: path)
        #expect(run().status == 0)
        try write("\(path)\tText(\"Hello\")\n", to: HardCodedBaseline.path)
        let checked = run("--check")
        #expect(checked.status == 1)
        #expect(
            errors(checked.log).map { String($0.prefix { $0 != ";" }) } == [
                "error: Localization/hardcoded-strings-baseline.txt:1: Audiobookshelf/Features/A/A.swift: "
                    + "no longer hard-coded (or the line changed)"
            ])
    }

    @Test func malformedBaselineFails() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write("no tab here\n", to: HardCodedBaseline.path)
        let checked = run("--check")
        #expect(checked.status == 1)
        #expect(checked.log.contains { $0.contains("hardcoded-strings-baseline.txt:1: expected") })
    }

    /// Every imported locale must be in `CFBundleLocalizations`: one missing of several fails.
    @Test func infoPlistMissingOneLocaleFails() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write(#"{"ButtonCancel": "Annuler"}"#, to: "strings/fr.json")
        try write(plist(["en", "de", "fr"]), to: ImportCommand.infoPlistPath)
        #expect(run().status == 0)
        #expect(run("--check").status == 0)
        try write(plist(["en", "fr"]), to: ImportCommand.infoPlistPath)
        let checked = run("--check")
        #expect(checked.status == 1)
        #expect(checked.log.contains { $0.contains("CFBundleLocalizations in Audiobookshelf/Info.plist") })
    }
}
