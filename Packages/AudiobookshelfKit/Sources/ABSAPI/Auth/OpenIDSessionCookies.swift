import Foundation

/// The cookies an OpenID sign-in leaves in the sign-in client's jar that `POST /logout` needs.
///
/// The server reads the auth method and ID token for the identity provider's end-session URL
/// only from its `auth_method` and `openid_id_token` cookies. The account stores these values
/// with its tokens and replays them on sign-out (``AuthEndpoints/logout(refreshToken:openIDSession:)``)
/// so the server returns `redirect_url`. The values are raw cookie values, kept as the server set
/// them; the ID token identifies the user, so it's redacted from descriptions.
public struct OpenIDSessionCookies: Sendable, Hashable, Codable {
    static let authMethodName = "auth_method"
    static let idTokenName = "openid_id_token"

    /// The `auth_method` cookie, `openid-mobile` after a mobile sign-in.
    public let authMethod: String
    /// The `openid_id_token` cookie, the identity provider's ID token. The server sends it as
    /// `id_token_hint`; without it the identity provider may ask before signing out.
    public let idToken: String?

    /// `nil` if a value can't be sent in a `Cookie` header.
    public init?(authMethod: String, idToken: String?) {
        guard Self.isCookieValue(authMethod), idToken.map(Self.isCookieValue) ?? true else { return nil }
        self.authMethod = authMethod
        self.idToken = idToken
    }

    /// The values of the two cookies in `cookies`; `nil` without an `auth_method` cookie.
    init?(cookies: [HTTPCookie]) {
        func value(_ name: String) -> String? { cookies.last { $0.name == name }?.value }
        guard let authMethod = value(Self.authMethodName) else { return nil }
        self.init(authMethod: authMethod, idToken: value(Self.idTokenName))
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let authMethod = try container.decode(String.self, forKey: .authMethod)
        let idToken = try container.decodeIfPresent(String.self, forKey: .idToken)
        guard let cookies = Self(authMethod: authMethod, idToken: idToken) else {
            throw DecodingError.dataCorruptedError(
                forKey: .authMethod, in: container, debugDescription: "Not a cookie value")
        }
        self = cookies
    }

    /// The `Cookie` header value.
    var headerValue: String {
        var pairs = ["\(Self.authMethodName)=\(authMethod)"]
        if let idToken { pairs.append("\(Self.idTokenName)=\(idToken)") }
        return pairs.joined(separator: "; ")
    }

    /// RFC 6265 `cookie-octet`s: printable ASCII except space, `"`, `,`, `;` and `\`.
    private static func isCookieValue(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.allSatisfy { (0x21...0x7E).contains($0) && ![0x22, 0x2C, 0x3B, 0x5C].contains($0) }
    }
}

extension OpenIDSessionCookies: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "OpenIDSessionCookies(authMethod: \(authMethod), idToken: \(idToken == nil ? "nil" : "<redacted>"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self, children: ["authMethod": authMethod, "idToken": idToken == nil ? "nil" : "<redacted>"],
            displayStyle: .struct)
    }
}
