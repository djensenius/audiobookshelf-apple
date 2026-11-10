import CryptoKit
import Foundation

/// A Proof Key for Code Exchange pair (RFC 7636): a random code verifier and its `S256`
/// challenge.
///
/// The verifier is a secret until the sign-in finishes; printing or dumping a value never
/// shows it.
struct PKCE: Sendable, Equatable {
    /// The `code_challenge_method` this type produces.
    static let method = "S256"
    /// RFC 7636 §4.1 allows 43–128 characters.
    static let verifierLengths = 43...128
    /// The unreserved characters of RFC 3986 §2.3, which RFC 7636 §4.1 allows in a verifier.
    static let verifierCharacters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Sent with the token request, as `code_verifier`.
    let verifier: String
    /// `BASE64URL(SHA256(ASCII(verifier)))` without padding, sent with the authorization request.
    let challenge: String

    /// A pair with a new 64-character verifier from the system's cryptographically secure
    /// random number generator.
    init() {
        var generator = SystemRandomNumberGenerator()
        self.init(verifier: Self.randomVerifier(length: 64, using: &generator))
    }

    init(verifier: String) {
        self.verifier = verifier
        challenge = Self.challenge(for: verifier)
    }

    /// A verifier of `length` characters, each drawn uniformly from ``verifierCharacters``.
    static func randomVerifier(length: Int, using generator: inout some RandomNumberGenerator) -> String {
        precondition(verifierLengths.contains(length), "RFC 7636 verifiers have 43 to 128 characters")
        var characters: [Character] = []
        characters.reserveCapacity(length)
        for _ in 0..<length {
            // `verifierCharacters` is a non-empty constant.
            characters.append(verifierCharacters.randomElement(using: &generator) ?? "A")
        }
        return String(characters)
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}

extension PKCE: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "PKCE(verifier: <redacted>, challenge: \(challenge))" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["verifier": "<redacted>", "challenge": challenge], displayStyle: .struct)
    }
}

extension Data {
    /// Base64url (RFC 4648 §5) without padding.
    fileprivate func base64URLEncodedString() -> String {
        var text = base64EncodedString()
        text = text.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        while text.hasSuffix("=") { text.removeLast() }
        return text
    }
}
