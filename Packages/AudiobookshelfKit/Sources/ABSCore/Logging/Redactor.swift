import Foundation

/// Removes credentials from text before it is logged or exported.
///
/// Always redacts:
/// - `Bearer` credentials (`Authorization: Bearer abc` becomes `Authorization: Bearer <redacted>`),
/// - values of token and OAuth query parameters (`token`, `access_token`, `refresh_token`,
///   `accessToken`, `refreshToken`, `code`, `code_verifier`), in URLs or as bare `name=value` text;
///   names match in any case and after percent-decoding, and malformed encoded names are redacted,
/// - JSON `"password"` values,
/// - JSON Web Tokens anywhere in the text (three base64url segments whose first two decode to
///   JSON objects, the first with an `"alg"` key).
///
/// Custom header values can't be recognised by pattern, so pass them in as `secrets`. Anything
/// else, such as a sensitive number logged with public privacy, passes through unchanged; see
/// ``Log`` for the privacy rules.
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
        ranges += Self.sensitiveParameterValues(in: original)
        for match in Self.jwtCandidate.regex.matches(in: text, range: whole)
        where Self.isJWT(
            header: original.substring(with: match.range(withName: "header")),
            claims: original.substring(with: match.range(withName: "claims"))
        ) {
            ranges.append(match.range(withName: "value"))
        }
        for secret in secrets where secret.count >= Self.minimumSecretLength {
            var search = whole
            while true {
                let found = original.range(of: secret, options: .literal, range: search)
                guard found.location != NSNotFound else { break }
                ranges.append(found)
                // Resume just after the start so overlapping occurrences are found too; merging
                // combines them. Each search costs about the secret's length, so this stays linear
                // in the number of occurrences.
                let next = found.location + 1
                search = NSRange(location: next, length: whole.upperBound - next)
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

    /// Whether `header` and `claims` are base64url-encoded JSON objects and the header has an `alg`.
    private static func isJWT(header: String, claims: String) -> Bool {
        guard let header = jsonObject(base64URL: header), header["alg"] != nil else { return false }
        return jsonObject(base64URL: claims) != nil
    }

    /// Decodes a base64url segment (padding optional) as a JSON object. Segments longer than
    /// ``maximumJWTSegmentLength`` aren't decoded, which bounds the work per candidate.
    private static func jsonObject(base64URL segment: String) -> [String: Any]? {
        guard segment.utf8.count <= maximumJWTSegmentLength, segment.utf8.count % 4 != 1 else { return nil }
        var base64 = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static let maximumJWTSegmentLength = 16_384

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
        // JSON passwords, including escaped characters such as `\"`.
        Rule(#""password"\s*:\s*"(?<value>(?:[^"\\]|\\.)*)"#),
    ]

    /// Token and OAuth (PKCE) parameter names, lowercased. Compared after percent-decoding.
    private static let sensitiveParameterNames: Set<String> = [
        "token", "access_token", "accesstoken", "refresh_token", "refreshtoken", "code", "code_verifier",
    ]

    /// Whether a query parameter name is sensitive once percent-decoded, ignoring case
    /// (`%74oken`, `access%5Ftoken`, `TOKEN`). Names whose encoding is malformed or nested too
    /// deeply to decode count as sensitive, so they fail closed.
    private static func isSensitiveParameter(_ name: String) -> Bool {
        var decoded = name
        for _ in 0..<3 where decoded.contains("%") {
            guard let next = decoded.removingPercentEncoding else { return true }
            decoded = next
        }
        if decoded.contains("%") { return true }
        return sensitiveParameterNames.contains(decoded.lowercased())
    }

    /// The `name=` part of a `name=value` pair at the start of a line or after `?`, `&`, `;`, or
    /// whitespace, in URLs or bare text. Names can't contain a separator, so each start position
    /// scans a disjoint run and matching is linear. Only `name=` is consumed, so a pair inside
    /// another value (`a=1;token=x`) is still found.
    private static let parameterName = Rule(#"(?<![^?&;\s])(?<name>[^=&#\s"<>?;]++)="#, options: [])

    /// Value ranges of every parameter whose name is sensitive (see ``isSensitiveParameter(_:)``).
    ///
    /// A value runs to the next `&`, `#`, whitespace, `"`, `<`, or `>`. It may contain any other
    /// character that's valid unescaped in a query (`'`, `!`, `*`, `(`, `)`, `~`, `$`, `,`, `;`, `:`,
    /// `@`, `/`, `?`); `"`, `<`, and `>` aren't, so `"…"` or `<…>` around a URL survives. A closing
    /// `)` or `'` around a URL is redacted with the value: hiding one extra character is safer than
    /// leaking a value that contains it.
    ///
    /// Values are scanned only for sensitive names, and never past text already scanned: a value
    /// that starts inside the previous sensitive value ends at the same terminator, so it's already
    /// covered. The whole pass is linear in the length of `text`.
    private static func sensitiveParameterValues(in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var scannedUntil = 0
        let whole = NSRange(location: 0, length: text.length)
        for match in parameterName.regex.matches(in: text as String, range: whole) {
            let valueStart = match.range.upperBound
            guard valueStart >= scannedUntil,
                isSensitiveParameter(text.substring(with: match.range(withName: "name")))
            else { continue }
            var valueEnd = valueStart
            while valueEnd < text.length, !isValueTerminator(text.character(at: valueEnd)) {
                valueEnd += 1
            }
            ranges.append(NSRange(location: valueStart, length: valueEnd - valueStart))
            scannedUntil = valueEnd
        }
        return ranges
    }

    private static func isValueTerminator(_ unit: unichar) -> Bool {
        switch unit {
        case 0x22, 0x23, 0x26, 0x3C, 0x3E: true  // " # & < >
        default: Unicode.Scalar(unit)?.properties.isWhitespace ?? false
        }
    }

    /// Three dot-separated base64url segments that aren't part of a longer dotted run, such as a
    /// hostname with more labels. ``isJWT(header:claims:)`` checks the `header` and `claims` groups.
    /// Possessive quantifiers and the lookbehind keep matching linear.
    private static let jwtCandidate = Rule(
        #"(?<![A-Za-z0-9_.-])(?<value>(?<header>[A-Za-z0-9_-]++)\.(?<claims>[A-Za-z0-9_-]++)\.[A-Za-z0-9_-]*+)(?!\.?[A-Za-z0-9_-])"#,
        options: []
    )
}

extension Redactor: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    // Never print the secrets themselves.
    public var description: String { "Redactor(\(secrets.count) secrets)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["secretCount": secrets.count]) }
}
