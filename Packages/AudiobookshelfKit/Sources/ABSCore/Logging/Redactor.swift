import Foundation

/// Removes credentials from text before it is logged or exported.
///
/// Always redacts:
/// - `Bearer` credentials (`Authorization: Bearer abc` becomes `Authorization: Bearer <redacted>`),
/// - values of token query parameters (`token`, `access_token`, `refresh_token`, `accessToken`,
///   `refreshToken`),
/// - JSON Web Tokens anywhere in the text.
///
/// Custom header values can't be recognised by pattern, so pass them in as `secrets`.
public struct Redactor: Sendable, Equatable {
    /// Replacement for every redacted value.
    public static let placeholder = "<redacted>"

    /// Exact values to remove wherever they appear, such as custom header values.
    public var secrets: [String]

    public init(secrets: [String] = []) {
        self.secrets = secrets
    }

    public func redact(_ text: String) -> String {
        var result = text
        // Longest first so a secret that contains another is removed whole.
        for secret in secrets.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: secret, with: Self.placeholder)
        }
        for rule in Self.rules {
            result = rule.apply(to: result)
        }
        return result
    }

    private struct Rule: Sendable {
        let regex: NSRegularExpression
        let template: String

        init(_ pattern: String, keeping prefix: String) {
            // The patterns are constants, so failing to compile one is a programming error.
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                preconditionFailure("Invalid redaction pattern: \(pattern)")
            }
            self.regex = regex
            self.template = prefix + NSRegularExpression.escapedTemplate(for: Redactor.placeholder)
        }

        func apply(to text: String) -> String {
            regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: template
            )
        }
    }

    private static let rules = [
        // Bearer credentials, whether a JWT or an opaque token.
        Rule(#"(\bBearer\s+)[^\s,;"']+"#, keeping: "$1"),
        // Token query parameters in URLs.
        Rule(#"([?&;](?:access_?token|refresh_?token|token)=)[^&#\s"']*"#, keeping: "$1"),
        // Any JWT left over, for example inside a JSON body.
        Rule(#"\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*"#, keeping: ""),
    ]
}
