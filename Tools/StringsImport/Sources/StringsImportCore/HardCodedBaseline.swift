import Foundation

/// The hard-coded user-facing strings accepted until they're localized: one per line of
/// ``path`` as `<file path>\t<the line's trimmed source>`, with `#` comments and blank lines
/// ignored. A line with two such strings needs two entries.
///
/// Entries match by file and source, not line number, so code moving around a file keeps its
/// entry. A string with no entry fails `strings:check`, and so does an entry that matches
/// nothing (the string was localized, edited or moved to another file), so the list only shrinks.
public struct HardCodedBaseline: Sendable, Equatable {
    public static let path = "Localization/hardcoded-strings-baseline.txt"

    public struct Entry: Hashable, Sendable, CustomStringConvertible {
        public var path: String
        public var code: String

        public init(path: String, code: String) {
            self.path = path
            self.code = code
        }

        public var description: String { "\(path)\t\(code)" }
    }

    /// The entries in file order, with their 1-based line numbers in the baseline file.
    public var entries: [(line: Int, entry: Entry)]

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entries.map(\.line) == rhs.entries.map(\.line) && lhs.entries.map(\.entry) == rhs.entries.map(\.entry)
    }

    /// Parses the baseline file's text; a line that isn't a comment, blank or `path\tcode` throws.
    public init(text: String) throws {
        entries = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = line.split(separator: "\t", maxSplits: 1)
            let code = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            guard parts.count == 2, !parts[0].isEmpty, !code.isEmpty else {
                throw ImportError.invalidBaselineLine(line: index + 1)
            }
            entries.append((index + 1, Entry(path: String(parts[0]), code: code)))
        }
    }

    /// The baseline at ``path`` under `root`; empty if there's no file.
    public static func load(root: URL) throws -> HardCodedBaseline {
        let url = root.appending(path: path)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return try HardCodedBaseline(text: "")
        }
        return try HardCodedBaseline(text: String(contentsOf: url, encoding: .utf8))
    }

    /// Splits `strings` into those with no entry (`new`) and returns the entries that matched
    /// none of them (`stale`, with their baseline line numbers). Each entry accepts one string.
    public func match(_ strings: [SourceScanner.HardCodedString]) -> (
        new: [SourceScanner.HardCodedString], stale: [(line: Int, entry: Entry)]
    ) {
        var unmatched: [Entry: [Int]] = [:]
        for (line, entry) in entries { unmatched[entry, default: []].append(line) }
        var new: [SourceScanner.HardCodedString] = []
        for string in strings {
            let entry = Entry(path: string.path, code: string.code)
            if let lines = unmatched[entry], !lines.isEmpty {
                unmatched[entry] = Array(lines.dropFirst())
            } else {
                new.append(string)
            }
        }
        let stale = entries.filter { line, entry in unmatched[entry]?.contains(line) == true }
        return (new, stale)
    }
}
