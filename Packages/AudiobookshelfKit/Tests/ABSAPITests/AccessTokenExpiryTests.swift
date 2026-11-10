import Foundation
import Testing

@testable import ABSAPI

@Suite struct AccessTokenExpiryTests {
    /// `>>>?` encodes to both `-` and `_`; the `p` values give unpadded payload lengths with
    /// every remainder base64url allows (0, 2 and 3 modulo 4).
    @Test(arguments: ["", "x", "xx"])
    func readsExpAcrossBase64URLPaddingCases(padding: String) throws {
        let claims = #"{"exp":1700000000,"n":">>>?","p":"\#(padding)"}"#
        let token = makeJWT(claims: claims)
        let payload = try #require(token.split(separator: ".").dropFirst().first)
        #expect(payload.contains("-") && payload.contains("_"))
        #expect(payload.utf8.count % 4 != 1)

        #expect(AccessTokenExpiry(token: token) == AccessTokenExpiry(expiresAt: 1_700_000_000, issuedAt: nil))
    }

    @Test func coversEveryPaddingRemainder() {
        let remainders = Set(
            ["", "x", "xx"].map { base64URL(#"{"exp":1700000000,"n":">>>?","p":"\#($0)"}"#).utf8.count % 4 })
        #expect(remainders == [0, 2, 3])
    }

    @Test func acceptsPaddedPayloadAndFractionalExp() {
        let payload = Data(#"{"exp":1700000000.5}"#.utf8).base64EncodedString()
        #expect(payload.hasSuffix("="))
        #expect(AccessTokenExpiry(token: "e30.\(payload).sig")?.expiresAt == 1_700_000_000.5)
    }

    /// The standard alphabet is accepted as well as base64url.
    @Test func acceptsStandardAlphabet() throws {
        let payload = Data(#"{"exp":1700000000,"n":">>>?"}"#.utf8).base64EncodedString()
        #expect(payload.contains("+") && payload.contains("/"))
        #expect(AccessTokenExpiry(token: "e30.\(payload).sig")?.expiresAt == 1_700_000_000)
    }

    @Test func readsIssuedAtAndIgnoresUnreadableIssuedAt() {
        #expect(
            AccessTokenExpiry(token: makeJWT(claims: #"{"iat":1699996400,"exp":1700000000}"#))
                == AccessTokenExpiry(expiresAt: 1_700_000_000, issuedAt: 1_699_996_400))
        #expect(
            AccessTokenExpiry(token: makeJWT(claims: #"{"iat":"soon","exp":1700000000}"#))
                == AccessTokenExpiry(expiresAt: 1_700_000_000, issuedAt: nil))
    }

    /// Any finite `exp` is kept, including ones at or before the epoch (already expired).
    @Test(arguments: [("1e300", 1e300), ("0", 0), ("-5", -5)])
    func keepsFiniteExp(exp: String, expected: Double) {
        #expect(AccessTokenExpiry(token: makeJWT(claims: #"{"exp":\#(exp)}"#))?.expiresAt == expected)
    }

    @Test(arguments: [
        "access-1",
        "",
        "a.b",
        "e30.e30.sig.extra",
        "e30.!!!.sig",
        "e30.e.sig",
        makeJWT(claims: "{}"),
        makeJWT(claims: #"{"exp":"1700000000"}"#),
        makeJWT(claims: #"{"exp":null}"#),
        makeJWT(claims: #"{"exp":true}"#),
        makeJWT(claims: #"{"exp":1e400}"#),
        makeJWT(claims: "[1700000000]"),
        "e30." + base64URL("not json") + ".sig",
    ])
    func unreadableTokensHaveUnknownExpiry(token: String) {
        #expect(AccessTokenExpiry(token: token) == nil)
    }

    @Test func segmentOverLimitIsNotRead() {
        let claims = #"{"exp":1700000000,"p":"\#(String(repeating: "x", count: 12_300))"}"#
        #expect(base64URL(claims).utf8.count > AccessTokenExpiry.maximumSegmentLength)
        #expect(AccessTokenExpiry(token: makeJWT(claims: claims)) == nil)
    }

    @Test func segmentAtLimitIsRead() throws {
        let prefix = #"{"exp":1700000000,"p":""#
        let fill = AccessTokenExpiry.maximumSegmentLength / 4 * 3 - prefix.utf8.count - 2
        let claims = prefix + String(repeating: "x", count: fill) + #""}"#
        #expect(base64URL(claims).utf8.count == AccessTokenExpiry.maximumSegmentLength)
        #expect(AccessTokenExpiry(token: makeJWT(claims: claims))?.expiresAt == 1_700_000_000)
    }
}
