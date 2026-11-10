// Printing, dumping, or mirroring a token pair (for example inside ``LoginResult``) never shows
// the token values.
extension AuthTokens: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "AuthTokens(accessToken: <redacted>, refreshToken: <redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["accessToken": "<redacted>", "refreshToken": "<redacted>"], displayStyle: .struct)
    }
}
