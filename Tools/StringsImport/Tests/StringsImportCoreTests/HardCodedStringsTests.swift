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

    /// Only a real conformance makes a preview: an identifier containing `PreviewProvider` is
    /// production code.
    @Test func skipsOnlyPreviewProviderConformances() {
        let text = """
            struct PreviewProviderView: View {
                var body: some View { Text("Production") }
            }
            struct Row_Previews: Foo, PreviewProvider {
                static var previews: some View { Text("Preview") }
            }
            extension Row: SwiftUI.PreviewProvider {
                static var previews: some View { Text("Preview too") }
            }
            Text("After")
            """
        #expect(lines(text) == [2, 10])
    }

    /// A generic constraint or `where` clause naming `PreviewProvider` isn't a conformance, and a
    /// function isn't a preview type.
    @Test func genericConstraintsAreNotPreviews() {
        let text = """
            func render<T: PreviewProvider>(_ type: T.Type) -> some View { Text("Function") }
            struct Box<T: PreviewProvider>: View {
                var body: some View { Text("Generic") }
            }
            extension Box: Equatable where T: PreviewProvider {
                var label: some View { Text("Where") }
            }
            struct Row_Previews: PreviewProvider {
                static var previews: some View { Text("Preview") }
            }
            """
        #expect(lines(text) == [1, 3, 6])
    }

    /// A conformance on a later line of the declaration, before its body, still makes a preview,
    /// header lines included.
    @Test func multilinePreviewConformances() {
        let text = """
            struct Row_Previews:
                PreviewProvider
            {
                static var previews: some View { Text("Preview") }
            }
            @available(iOS 18, *)
            struct Other_Previews: View,
                SwiftUI.PreviewProvider {
                static var previews: some View { Text("Preview too") }
            }
            struct Plain:
                View {
                var body: some View { Text("Production") }
            }
            Text("After")
            """
        #expect(lines(text) == [13, 15])
    }

    /// Only a condition that is exactly `DEBUG` is skipped: a compound one also builds in release.
    @Test func skipsOnlyExactDebugConditions() {
        let text = """
            #if DEBUG || os(macOS)
            Text("macOS release")
            #endif
            #if DEBUG && os(iOS)
            Text("Not handled: debug and iOS")
            #endif
            #if DEBUG  // A note.
            Text("Debug")
            #endif
            """
        #expect(lines(text) == [2, 5])
    }

    /// CRLF and lone CR line breaks number lines like LF ones. Swift reads `\r\n` as one
    /// character, so before normalizing, the comment-stripped text (whose comment blanked the
    /// `\r`) had more lines than the original and the scan indexed past it.
    @Test func numbersCRLFAndCRLinesLikeLF() {
        #expect(lines("// comment\r\nText(\"Hello\")\r\n") == [2])
        #expect(lines("let a = 1\rText(\"Hello\")\r\nText(\"Again\")") == [2, 3])
        let found = SourceScanner.hardCodedStrings(
            in: .init(path: "Audiobookshelf/Features/A/A.swift", text: "// a\r\n    Text(\"Hello\")  \r\n"), keys: [])
        #expect(found.map(\.code) == [#"Text("Hello")"#])
        #expect(SourceScanner.SourceFile(path: "A.swift", text: "a\r\nb\rc\n").text == "a\nb\nc\n")
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

    /// Additions over the target branch's baseline count duplicates: removing entries is fine,
    /// a second copy of an entry is an addition.
    @Test func additionsAreAMultisetDifference() throws {
        let hello = "\(features)\tText(\"Hello\")"
        let bye = "\(features)\tText(\"Bye\")"
        let base = try HardCodedBaseline(text: "\(hello)\n\(bye)\n")
        #expect(try HardCodedBaseline(text: "\(hello)\n\(bye)\n").additions(over: base).isEmpty)
        #expect(try HardCodedBaseline(text: "# Removed one\n\(bye)\n").additions(over: base).isEmpty)
        #expect(try HardCodedBaseline(text: "").additions(over: base).isEmpty)
        let duplicated = try HardCodedBaseline(text: "\(hello)\n\(bye)\n\(hello)\n").additions(over: base)
        #expect(duplicated.map(\.line) == [3])
        let added = try HardCodedBaseline(text: "\(hello)\n\(features)\tText(\"New\")\n").additions(over: base)
        #expect(added.map(\.entry.code) == [#"Text("New")"#])
        #expect(try base.additions(over: HardCodedBaseline(text: "")).count == 2)
    }

    @Test func baseRefFollowsTheTargetBranchInCI() {
        #expect(HardCodedBaseline.baseRef(environment: [:]) == "origin/main")
        #expect(HardCodedBaseline.baseRef(environment: ["GITHUB_BASE_REF": ""]) == "origin/main")
        #expect(HardCodedBaseline.baseRef(environment: ["GITHUB_BASE_REF": "release"]) == "origin/release")
        // A push to main compares with the commit before the push.
        #expect(HardCodedBaseline.baseRef(environment: ["STRINGS_BASELINE_BASE": "abc123"]) == "abc123")
        #expect(
            HardCodedBaseline.baseRef(environment: ["STRINGS_BASELINE_BASE": "", "GITHUB_BASE_REF": "main"])
                == "origin/main")
    }

    /// A baseline saved with CRLF or CR line breaks parses like LF: its comment header doesn't
    /// swallow the entries.
    @Test func parsesCRLFBaselines() throws {
        let lf = "# A comment\n\(features)\tText(\"Hello\")\n\(features)\tText(\"Bye\")\n"
        let expected = try HardCodedBaseline(text: lf)
        #expect(expected.entries.count == 2)
        #expect(try HardCodedBaseline(text: lf.replacingOccurrences(of: "\n", with: "\r\n")) == expected)
        #expect(try HardCodedBaseline(text: lf.replacingOccurrences(of: "\n", with: "\r")) == expected)
        #expect(throws: ImportError.invalidBaselineLine(line: 2)) {
            try HardCodedBaseline(text: "# A comment\r\nno tab\r\n")
        }
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

    /// Runs git in `root`, failing the test if it fails.
    func git(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments =
            [
                "git", "-C", root.path(percentEncoded: false), "-c", "user.name=Test", "-c",
                "user.email=test@example.com",
            ]
            + arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
    }

    /// Commits the tree, with `baseline` as the target branch's baseline when given.
    func commitBase(baseline: String? = nil) throws {
        if let baseline { try write(baseline, to: HardCodedBaseline.path) }
        try git("init", "-q")
        try git("add", "-A")
        try git("commit", "-q", "-m", "base")
    }

    /// A baseline entry for a new string that the target branch's baseline lacks fails, even
    /// though the entry matches; removing entries (with their strings) passes.
    @Test func baselineAdditionsOverTheBaseFail() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "Audiobookshelf/Features/A/A.swift"
        try write("Text(\"Old\")\nText(\"Older\")", to: path)
        try commitBase(baseline: "\(path)\tText(\"Old\")\n\(path)\tText(\"Older\")\n")
        #expect(run().status == 0)
        #expect(run("--check", "--baseline-base", "HEAD").status == 0)

        // Negative control: the same new string and entry pass without a readable base.
        try write("Text(\"Old\")\nText(\"Older\")\nText(\"New\")", to: path)
        try write(
            "\(path)\tText(\"Old\")\n\(path)\tText(\"Older\")\n\(path)\tText(\"New\")\n", to: HardCodedBaseline.path)
        let unchecked = run("--check", "--baseline-base", "no-such-ref")
        #expect(unchecked.status == 0)
        #expect(unchecked.log.contains { $0.hasPrefix("warning: can't read") && $0.contains("no-such-ref") })

        let checked = run("--check", "--baseline-base", "HEAD")
        #expect(checked.status == 1)
        #expect(
            errors(checked.log).map { String($0.prefix { $0 != ";" }) } == [
                "error: Localization/hardcoded-strings-baseline.txt:3: \(path): not in HEAD's baseline"
            ])

        // Removing a string and its entry passes.
        try write("Text(\"Old\")", to: path)
        try write("\(path)\tText(\"Old\")\n", to: HardCodedBaseline.path)
        #expect(run("--check", "--baseline-base", "HEAD").status == 0)
    }

    /// A base without the baseline file (before it existed) has no entries, so any entry is new.
    @Test func baseWithoutABaselineAcceptsNoEntries() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "Audiobookshelf/Features/A/A.swift"
        try write("Text(L10n.string(\"ButtonCancel\"))", to: path)
        #expect(run().status == 0)
        try commitBase()
        try write("Text(\"Hello\")", to: path)
        try write("\(path)\tText(\"Hello\")\n", to: HardCodedBaseline.path)
        #expect(run("--check", "--baseline-base", "HEAD").status == 1)
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
