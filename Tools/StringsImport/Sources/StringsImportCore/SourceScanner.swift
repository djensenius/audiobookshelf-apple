import Foundation

/// Scans the native Swift sources for the string keys they use and for hard-coded user-facing
/// strings. A line containing ``ignoreMarker`` (or following a comment line that does) is skipped
/// by both scans.
public enum SourceScanner {
    /// Swift sources whose keys must exist in the source strings files.
    public static let keyPaths = ["Audiobookshelf", "Packages/AudiobookshelfKit/Sources"]
    /// Swift sources that must not hard-code user-facing strings.
    public static let featuresPath = "Audiobookshelf/Features"
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

        /// Code lines with their 1-based numbers: comment lines and opted-out lines are dropped.
        var codeLines: [(number: Int, text: Substring)] {
            var result: [(Int, Substring)] = []
            var ignoreNext = false
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.drop { $0.isWhitespace }
                let isComment = trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*")
                let ignored = ignoreNext || line.contains(ignoreMarker)
                ignoreNext = isComment && line.contains(ignoreMarker)
                if !isComment, !ignored { result.append((index + 1, line)) }
            }
            return result
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
            for (number, line) in file.codeLines {
                guard line.contains("\"") else { continue }
                var keys: Set<String> = []
                for literal in identifierLiterals(in: line) {
                    mentioned.insert(literal)
                    if isKeyShaped(literal) { keys.insert(literal) }
                }
                // Checked first: Regex is slow in debug builds.
                let calls =
                    line.contains("L10n.") ? line.matches(of: /L10n\.(?:string|attributed|plural)\(\s*"([^"\\]+)"/) : []
                for match in calls {
                    let literal = String(match.output.1)
                    mentioned.insert(literal)
                    keys.insert(literal)
                }
                required += keys.sorted().map { KeyReference(key: $0, path: file.path, line: number) }
            }
        }
        return (required, mentioned)
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
            |ContentUnavailableView|ProgressView|GroupBox|DisclosureGroup|Tab)
          | \.(?:navigationTitle|navigationSubtitle|accessibilityLabel|accessibilityHint|accessibilityValue|help
            |alert|confirmationDialog)
        ) \( \s* (?:verbatim: \s*)? (?="[^"])
        | \bprompt: \s* (?="[^"])
        /#
    }

    /// String literals passed straight to a user-facing view or modifier (``userFacingCall``,
    /// `Text(verbatim:)` included) or a `prompt:` argument that contain a letter outside their
    /// interpolations and aren't a key in `keys`. Symbols and numbers (`"•"`, `"+"`) are allowed.
    public static func hardCodedStrings(in file: SourceFile, keys: Set<String>) -> [HardCodedString] {
        var result: [HardCodedString] = []
        for (number, line) in file.codeLines where line.contains("\"") {
            for match in line.matches(of: userFacingCall) {
                guard let (literal, text) = stringLiteral(at: match.range.upperBound, in: line) else { continue }
                guard text.contains(where: \.isLetter), !keys.contains(text) else { continue }
                result.append(HardCodedString(path: file.path, line: number, literal: literal))
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
                    // Skip the interpolation, nested parentheses and strings included.
                    var depth = 1
                    var inString = false
                    while depth > 0 {
                        index = line.index(after: index)
                        guard index < line.endIndex else { return nil }
                        switch line[index] {
                        case "\"": inString.toggle()
                        case "(" where !inString: depth += 1
                        case ")" where !inString: depth -= 1
                        default: break
                        }
                    }
                }
            } else {
                text.append(character)
            }
            index = line.index(after: index)
        }
        return nil
    }
}
