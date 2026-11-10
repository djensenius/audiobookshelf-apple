import Foundation

/// Removes credentials from text before it is logged or exported.
///
/// Always redacts:
/// - `Bearer` credentials (`Authorization: Bearer abc` becomes `Authorization: Bearer <redacted>`),
/// - values of token and OAuth query parameters (`token`, `access_token`, `refresh_token`,
///   `accessToken`, `refreshToken`, `code`, `code_verifier`), in URLs or as bare `name=value` text,
/// - JSON `"password"` values,
/// - JSON Web Tokens anywhere in the text.
///
/// Custom header values can't be recognised by pattern, so pass them in as `secrets`.
public struct Redactor: Sendable, Equatable {
    /// Replacement for every redacted value.
    public static let placeholder = "<redacted>"

    /// Secrets shorter than this are ignored, because replacing them would also mangle
    /// unrelated text.
    public static let minimumSecretLength = 4

    /// Exact values to remove wherever they appear, such as custom header values.
    /// Values shorter than ``minimumSecretLength`` are ignored.
    public var secrets: [String]

    public init(secrets: [String] = []) {
        self.secrets = secrets
    }

    public func redact(_ text: String) -> String {
        // Find every sensitive range in the original text before replacing anything, so a
        // custom secret can't break a built-in rule (for example a secret `pass` inside `"password"`).
        let original = text as NSString
        let whole = NSRange(location: 0, length: original.length)
        var ranges: [NSRange] = []
        for rule in Self.rules {
            for match in rule.regex.matches(in: text, range: whole) {
                ranges.append(match.range(withName: "value"))
            }
        }
        for secret in secrets where secret.count >= Self.minimumSecretLength {
            var search = whole
            while true {
                let found = original.range(of: secret, options: .literal, range: search)
                guard found.location != NSNotFound else { break }
                ranges.append(found)
                search = NSRange(location: found.upperBound, length: whole.upperBound - found.upperBound)
            }
        }

        let result = NSMutableString(string: original)
        for range in Self.merged(ranges).reversed() {
            result.replaceCharacters(in: range, with: Self.placeholder)
        }
        return result as String
    }

    /// Sorted, non-empty ranges with overlapping and adjacent ones combined.
    private static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var merged: [NSRange] = []
        for range in ranges.filter({ $0.location != NSNotFound && $0.length > 0 }).sorted(by: {
            $0.location < $1.location
        }) {
            if let last = merged.last, range.location <= last.upperBound {
                merged[merged.count - 1].length = max(last.upperBound, range.upperBound) - last.location
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// A pattern whose `value` capture group is the sensitive part of each match.
    private struct Rule: Sendable {
        let regex: NSRegularExpression

        init(_ pattern: String, options: NSRegularExpression.Options = [.caseInsensitive]) {
            // The patterns are constants, so failing to compile one is a programming error.
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                preconditionFailure("Invalid redaction pattern: \(pattern)")
            }
            self.regex = regex
        }
    }

    private static let rules = [
        // Bearer credentials, whether a JWT or an opaque token.
        Rule(#"\bBearer\s+(?<value>[^\s,;"']+)"#),
        // Token and OAuth (PKCE) query parameters, in URLs or bare `name=value` text.
        Rule(
            #"(?:^|[?&;\s])(?:access_?token|refresh_?token|token|code_verifier|code)=(?<value>[^&#\s"']*)"#,
            options: [.caseInsensitive, .anchorsMatchLines]
        ),
        // JSON passwords, including escaped characters such as `\"`.
        Rule(#""password"\s*:\s*"(?<value>(?:[^"\\]|\\.)*)"#),
        // Any JWT left over, for example inside a JSON body. JWTs always start with `eyJ`.
        Rule(#"\b(?<value>eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*)"#, options: []),
    ]
}

extension Redactor: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    // Never print the secrets themselves.
    public var description: String { "Redactor(\(secrets.count) secrets)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["secretCount": secrets.count]) }
}
