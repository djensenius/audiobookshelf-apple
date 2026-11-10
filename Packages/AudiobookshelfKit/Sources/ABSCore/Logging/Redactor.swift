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
        var result = text
        // Longest first so a secret that contains another is removed whole.
        let secrets = secrets.filter { $0.count >= Self.minimumSecretLength }.sorted { $0.count > $1.count }
        for secret in secrets {
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

        init(_ pattern: String, keeping prefix: String, options: NSRegularExpression.Options = [.caseInsensitive]) {
            // The patterns are constants, so failing to compile one is a programming error.
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
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
        // Token and OAuth (PKCE) query parameters, in URLs or bare `name=value` text.
        Rule(
            #"((?:^|[?&;\s])(?:access_?token|refresh_?token|token|code_verifier|code)=)[^&#\s"']*"#,
            keeping: "$1",
            options: [.caseInsensitive, .anchorsMatchLines]
        ),
        // JSON passwords.
        Rule(#"("password"\s*:\s*")[^"]*"#, keeping: "$1"),
        // Any JWT left over, for example inside a JSON body. JWTs always start with `eyJ`.
        Rule(#"\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*"#, keeping: "", options: []),
    ]
}

extension Redactor: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    // Never print the secrets themselves.
    public var description: String { "Redactor(\(secrets.count) secrets)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["secretCount": secrets.count]) }
}
