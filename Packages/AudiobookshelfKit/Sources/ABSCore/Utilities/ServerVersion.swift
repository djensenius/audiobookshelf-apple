import Foundation

/// An Audiobookshelf server version (`major.minor.patch`).
///
/// The server only uses `major.minor.patch`. Parsing accepts a leading `v`, one to three
/// numeric components (missing components are `0`), and ignores a pre-release or build
/// suffix (`-beta.1`, `+abc`).
public struct ServerVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Returns `nil` when `string` is empty or not a numeric version.
    public init?(_ string: String) {
        var trimmed = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        if trimmed.first == "v" || trimmed.first == "V" { trimmed = trimmed.dropFirst() }
        if let suffixStart = trimmed.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            trimmed = trimmed[..<suffixStart]
        }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else {
                return nil
            }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(numbers[0], numbers[1], numbers[2])
    }

    public static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}
