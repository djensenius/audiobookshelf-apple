import Foundation

/// The hard-coded user-facing strings accepted until they're localized: one per line of
/// ``path`` as `<file path>\t<the line's trimmed source>`, with `#` comments and blank lines
/// ignored. A line with two such strings needs two entries.
///
/// Entries match by file and source, not line number, so code moving around a file keeps its
/// entry. A string with no entry fails `strings:check`, and so does an entry that matches
/// nothing (the string was localized, edited or moved to another file). An entry the target
/// branch's baseline doesn't have fails too (``additions(over:)``), so the list only shrinks.
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

    /// The git ref whose baseline this one may only shrink from: `origin/<GITHUB_BASE_REF>` for a
    /// pull request in CI, else `origin/main`.
    public static func baseRef(environment: [String: String]) -> String {
        if let base = environment["GITHUB_BASE_REF"], !base.isEmpty { return "origin/\(base)" }
        return "origin/main"
    }

    /// The baseline at git `ref` in the repository at `root`: empty if the file isn't there at
    /// that ref, `nil` if git can't resolve the ref (not a repository, or a shallow clone that
    /// hasn't fetched it).
    public static func load(root: URL, ref: String) throws -> HardCodedBaseline? {
        guard git(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], root: root) != nil else { return nil }
        guard let text = git(["show", "\(ref):\(path)"], root: root) else { return try HardCodedBaseline(text: "") }
        return try HardCodedBaseline(text: text)
    }

    /// `git -C root <arguments>`'s standard output, or `nil` if it couldn't run or failed.
    private static func git(_ arguments: [String], root: URL) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["git", "-C", root.path(percentEncoded: false)] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The entries `base` doesn't have, counting duplicates (two equal entries here and one in
    /// `base` is one addition), with their line numbers in this baseline.
    public func additions(over base: HardCodedBaseline) -> [(line: Int, entry: Entry)] {
        var available: [Entry: Int] = [:]
        for (_, entry) in base.entries { available[entry, default: 0] += 1 }
        return entries.filter { _, entry in
            guard let count = available[entry], count > 0 else { return true }
            available[entry] = count - 1
            return false
        }
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
