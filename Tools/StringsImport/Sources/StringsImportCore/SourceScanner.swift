import Foundation

/// Scans the native Swift sources for the string keys they use and for hard-coded user-facing
/// strings. A line containing ``ignoreMarker`` (or following a comment line that does) is skipped
/// by both scans.
///
/// Comments are blanked out first by a small lexer (``SourceFile/codeText``) that knows string
/// literals (multi-line `"""` and raw `#"…"#` ones included), their interpolations and nested
/// block comments, so a `//` inside a string isn't a comment and a quote inside a comment isn't a
/// string. It is not a Swift parser: regex literals (`/"/`) aren't recognized, so a quote in one
/// can misread the rest of that line (a single-line string ends at its line); the hard-coded string
/// scan looks only at a view or modifier and its literal on one line; and a key passed through a
/// variable is found only if it has a key prefix (``isKeyShaped(_:)``).
public enum SourceScanner {
    /// Swift sources whose keys must exist in the source strings files.
    public static let keyPaths = ["Audiobookshelf", "Packages/AudiobookshelfKit/Sources"]
    /// Swift sources that must not hard-code user-facing strings, outside previews and `#if DEBUG`
    /// code (``SourceFile/previewAndDebugLines``).
    public static let hardCodedPaths = ["Audiobookshelf/Features", "Packages/AudiobookshelfKit/Sources/ABSUI"]

    /// Whether the file at `path` (relative to the repository root) is in ``hardCodedPaths``.
    public static func scansForHardCodedStrings(_ path: String) -> Bool {
        hardCodedPaths.contains { path.hasPrefix($0 + "/") }
    }
    /// The opt-out comment, e.g. `// l10n-ignore: an example URL, not prose`.
    public static let ignoreMarker = "l10n-ignore"

    /// One Swift file, with its path relative to the repository root.
    public struct SourceFile: Sendable, Equatable {
        public var path: String
        public var text: String

        public init(path: String, text: String) {
            self.path = path
            self.text = text
        }

        /// The 1-based numbers of the opted-out lines: those containing ``ignoreMarker``, and the
        /// line after a comment-only line that does. A line is comment-only when it has no code once
        /// comments are blanked, so `/* l10n-ignore */ Text(…)` opts out only its own line.
        var ignoredLines: Set<Int> {
            var result: Set<Int> = []
            var ignoreNext = false
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let codeLines = codeText.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                let isComment = index < codeLines.count && codeLines[index].allSatisfy(\.isWhitespace)
                if ignoreNext || line.contains(ignoreMarker) { result.insert(index + 1) }
                ignoreNext = isComment && line.contains(ignoreMarker)
            }
            return result
        }

        /// The text with every comment's characters replaced by spaces (newlines kept), so offsets
        /// and line numbers match ``text``.
        var codeText: String { String(decoding: SourceLexer.blankingComments(Array(text.utf8)), as: UTF8.self) }

        /// The 1-based numbers of the lines in previews (a `#Preview` or a `PreviewProvider` type,
        /// from its line to its closing brace) or in the `#if DEBUG` branch of a conditional (not
        /// its `#else`). Braces and `#` in comments and strings don't count.
        var previewAndDebugLines: Set<Int> {
            let code = String(decoding: SourceLexer.blankingComments(Array(text.utf8), strings: true), as: UTF8.self)
            var result: Set<Int> = []
            // One entry per open `#if`: whether its current branch is DEBUG code.
            var conditionals: [Bool] = []
            // The brace depth a preview started at while in one, and whether its body has opened.
            var previewDepth: Int?
            var previewOpened = false
            var depth = 0
            for (index, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let directive = line.drop { $0.isWhitespace }.split(whereSeparator: \.isWhitespace).map(String.init)
                switch directive.first {
                case "#if": conditionals.append(directive.dropFirst().first == "DEBUG")
                case "#elseif", "#else": if !conditionals.isEmpty { conditionals[conditionals.count - 1] = false }
                case "#endif": _ = conditionals.popLast()
                default: break
                }
                if previewDepth == nil, line.contains("#Preview") || line.contains("PreviewProvider") {
                    previewDepth = depth
                    previewOpened = false
                }
                let opened = line.filter { $0 == "{" }.count
                depth += opened - line.filter { $0 == "}" }.count
                if previewDepth != nil || conditionals.contains(true) { result.insert(index + 1) }
                // A preview ends when its braces close, once its body has opened.
                if let start = previewDepth {
                    previewOpened = previewOpened || opened > 0
                    if previewOpened, depth <= start { previewDepth = nil }
                }
            }
            return result
        }

        /// The lines of ``codeText`` with their 1-based numbers, opted-out lines dropped.
        var codeLines: [(number: Int, text: Substring)] {
            let ignored = ignoredLines
            return codeText.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                .compactMap { index, line in ignored.contains(index + 1) ? nil : (index + 1, line) }
        }
    }

    /// A string key used from Swift.
    public struct KeyReference: Sendable, Equatable, CustomStringConvertible {
        public var key: String
        public var path: String
        public var line: Int

        public var description: String { "\(path):\(line): \(key)" }
    }

    /// A user-facing string literal that isn't a key.
    public struct HardCodedString: Sendable, Equatable, CustomStringConvertible {
        public var path: String
        public var line: Int
        /// The literal as written, quotes included.
        public var literal: String
        /// The line's source, trimmed: what ``HardCodedBaseline`` matches, so an entry survives
        /// edits that only move the line.
        public var code: String = ""

        public var description: String { "\(path):\(line): \(literal)" }
    }

    /// Every `*.swift` file under `paths` (relative to `root`), sorted by path. Missing paths have none.
    public static func load(root: URL, paths: [String]) throws -> [SourceFile] {
        var files: [SourceFile] = []
        for path in paths {
            let directory = root.appending(path: path)
            let subpaths = FileManager.default.subpaths(atPath: directory.path(percentEncoded: false)) ?? []
            for subpath in subpaths where subpath.hasSuffix(".swift") {
                let text = try String(contentsOf: directory.appending(path: subpath), encoding: .utf8)
                files.append(SourceFile(path: "\(path)/\(subpath)", text: text))
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: - Keys

    /// The legacy naming prefixes (`ButtonCancel`, `LabelByAuthor`, …). A literal with one of them
    /// followed by an uppercase letter or digit is taken to be a key and must exist.
    public static let keyPrefixes = [
        "Button", "Header", "Label", "Message", "Note", "Placeholder", "Shared", "Toast", "Unit",
    ]

    /// Whether `literal` looks like a key by the legacy naming conventions.
    public static func isKeyShaped(_ literal: String) -> Bool {
        keyPrefixes.contains { prefix in
            literal.hasPrefix(prefix)
                && literal.dropFirst(prefix.count).first.map { $0.isUppercase || $0.isNumber } == true
        }
    }

    /// The keys `files` use.
    ///
    /// - `required`: the literal first argument of `L10n.string`, `L10n.attributed` or `L10n.plural`,
    ///   and any identifier literal shaped like a key (``isKeyShaped(_:)``), since keys are often passed
    ///   through properties and ternaries before reaching `L10n`.
    /// - `mentioned`: every identifier-like literal, `"LabelFoo"`, to tell which keys are still used.
    public static func keyReferences(in files: [SourceFile]) -> (required: [KeyReference], mentioned: Set<String>) {
        var required: [KeyReference] = []
        var mentioned: Set<String> = []
        for file in files {
            let code = Array(file.codeText.utf8)
            let ignored = file.ignoredLines
            // Calls may wrap after `(`, so they're matched in the whole text, at the literal's line.
            var callKeys: [Int: Set<String>] = [:]
            for (line, literal) in l10nCallKeys(in: code) where !ignored.contains(line) {
                mentioned.insert(literal)
                callKeys[line, default: []].insert(literal)
            }
            for (number, line) in file.codeLines {
                guard line.contains("\"") else { continue }
                var keys = callKeys[number] ?? []
                for literal in identifierLiterals(in: line) {
                    mentioned.insert(literal)
                    if isKeyShaped(literal) { keys.insert(literal) }
                }
                required += keys.sorted().map { KeyReference(key: $0, path: file.path, line: number) }
            }
        }
        return (required, mentioned)
    }

    /// The literal first arguments of `L10n.string(`, `L10n.attributed(` and `L10n.plural(` in
    /// `code` (comments blanked), with the 1-based line of each literal. Whitespace and newlines may
    /// come between `(` and the literal. Found without Regex, which is slow in debug builds.
    static func l10nCallKeys(in code: [UInt8]) -> [(line: Int, key: String)] {
        let prefix = Array("L10n.".utf8)
        let names = ["string(", "attributed(", "plural("].map { Array($0.utf8) }
        var result: [(Int, String)] = []
        var line = 1
        var index = 0
        while index < code.count {
            if code[index] == UInt8(ascii: "\n") { line += 1 }
            guard code[index...].starts(with: prefix) else {
                index += 1
                continue
            }
            index += prefix.count
            guard let name = names.first(where: { code[index...].starts(with: $0) }) else { continue }
            index += name.count
            while index < code.count,
                code[index] == UInt8(ascii: " ") || code[index] == UInt8(ascii: "\t")
                    || code[index] == UInt8(ascii: "\n") || code[index] == UInt8(ascii: "\r")
            {
                if code[index] == UInt8(ascii: "\n") { line += 1 }
                index += 1
            }
            guard index < code.count, code[index] == UInt8(ascii: "\""),
                !code[index...].starts(with: Array("\"\"\"".utf8))
            else { continue }
            var end = index + 1
            while end < code.count, ![UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "\n")].contains(code[end]) {
                end += 1
            }
            if end > index + 1, end < code.count, code[end] == UInt8(ascii: "\"") {
                result.append((line, String(decoding: code[(index + 1)..<end], as: UTF8.self)))
                index = end + 1
            } else {
                index += 1
            }
        }
        return result
    }

    /// The contents of `"…"` spans in `line` that are identifiers (`"LabelFoo"`), found without
    /// Regex, which is slow in debug builds. A span between two literals (`"a" + "b"`) has spaces, and
    /// one inside an interpolation (`"\(L10n.string("Key"))"`) still starts after a quote.
    static func identifierLiterals(in line: Substring) -> [String] {
        var result: [String] = []
        let characters = Array(line.utf8)
        var index = 0
        while index < characters.count {
            guard characters[index] == UInt8(ascii: "\""), index + 1 < characters.count else {
                index += 1
                continue
            }
            var end = index + 1
            while end < characters.count, isIdentifierCharacter(characters[end], first: end == index + 1) {
                end += 1
            }
            if end > index + 1, end < characters.count, characters[end] == UInt8(ascii: "\"") {
                result.append(String(decoding: characters[(index + 1)..<end], as: UTF8.self))
                index = end + 1
            } else {
                index += 1
            }
        }
        return result
    }

    private static func isIdentifierCharacter(_ byte: UInt8, first: Bool) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"): true
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"): !first
        default: false
        }
    }

    // MARK: - Hard-coded strings

    /// SwiftUI views and modifiers whose first argument is shown to the user; a literal there is
    /// localized by SwiftUI from the app's bundle, which has no strings, or isn't localized at all.
    private static var userFacingCall: Regex<Substring> {
        #/
        (?:
            (?:^|[^\w.])
            (?:Text|Button|Label|Toggle|Picker|Section|Menu|TextField|SecureField|Link|LabeledContent
            |ContentUnavailableView|ProgressView|GroupBox|DisclosureGroup|Tab|NavigationLink|ShareLink
            |DatePicker|Stepper)
          | \.(?:navigationTitle|navigationSubtitle|accessibilityLabel|accessibilityHint|accessibilityValue|help
            |alert|confirmationDialog)
        ) \( \s* (?:verbatim: \s*)? (?="[^"])
        | \bprompt: \s* (?="[^"])
        /#
    }

    /// String literals passed straight to a user-facing view or modifier (``userFacingCall``,
    /// `Text(verbatim:)` included) or a `prompt:` argument that contain a letter outside their
    /// interpolations and aren't a key in `keys`. Symbols and numbers (`"•"`, `"+"`) are allowed,
    /// and previews and `#if DEBUG` code aren't checked.
    public static func hardCodedStrings(in file: SourceFile, keys: Set<String>) -> [HardCodedString] {
        var result: [HardCodedString] = []
        let skipped = file.previewAndDebugLines
        let lines = file.text.split(separator: "\n", omittingEmptySubsequences: false)
        for (number, line) in file.codeLines where line.contains("\"") && !skipped.contains(number) {
            for match in line.matches(of: userFacingCall) {
                guard let (literal, text) = stringLiteral(at: match.range.upperBound, in: line) else { continue }
                guard text.contains(where: \.isLetter), !keys.contains(text) else { continue }
                let code = lines[number - 1].trimmingCharacters(in: .whitespaces)
                result.append(HardCodedString(path: file.path, line: number, literal: literal, code: code))
            }
        }
        return result
    }

    /// The single-line string literal starting at `start` (a `"`): the literal as written and its
    /// text without interpolations. `nil` for multi-line or unterminated literals.
    private static func stringLiteral(at start: Substring.Index, in line: Substring) -> (String, String)? {
        guard line[start...].hasPrefix("\""), !line[start...].hasPrefix("\"\"\"") else { return nil }
        var text = ""
        var index = line.index(after: start)
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                return (String(line[start...index]), text)
            }
            if character == "\\" {
                index = line.index(after: index)
                guard index < line.endIndex else { return nil }
                if line[index] == "(" {
                    // Skip the interpolation, nested parentheses and strings (and their escapes) included.
                    var depth = 1
                    var inString = false
                    while depth > 0 {
                        index = line.index(after: index)
                        guard index < line.endIndex else { return nil }
                        switch line[index] {
                        case "\\" where inString:
                            index = line.index(after: index)
                            guard index < line.endIndex else { return nil }
                        case "\"": inString.toggle()
                        case "(" where !inString: depth += 1
                        case ")" where !inString: depth -= 1
                        default: break
                        }
                    }
                } else if line[index] == "u" {
                    // `\u{…}`: its scalar, so `\u{202F}` is a symbol and `\u{65}` a letter.
                    guard let (scalar, end) = unicodeEscape(after: index, in: line) else { return nil }
                    text.unicodeScalars.append(scalar)
                    index = end
                } else if let escaped = simpleEscapes[line[index]] {
                    text.append(escaped)
                }
            } else {
                text.append(character)
            }
            index = line.index(after: index)
        }
        return nil
    }

    /// Swift's single-character escapes and what they stand for.
    private static let simpleEscapes: [Character: Character] = [
        "0": "\0", "\\": "\\", "t": "\t", "n": "\n", "r": "\r", "\"": "\"", "'": "'",
    ]

    /// The scalar of the `\u{…}` escape whose `u` is at `u`, and the index of its `}`; `nil` if
    /// it's malformed.
    private static func unicodeEscape(
        after u: Substring.Index, in line: Substring
    ) -> (Unicode.Scalar, Substring.Index)? {
        let open = line.index(after: u)
        guard open < line.endIndex, line[open] == "{",
            let close = line[open...].firstIndex(of: "}"),
            let value = UInt32(line[line.index(after: open)..<close], radix: 16),
            let scalar = Unicode.Scalar(value)
        else { return nil }
        return (scalar, close)
    }
}
