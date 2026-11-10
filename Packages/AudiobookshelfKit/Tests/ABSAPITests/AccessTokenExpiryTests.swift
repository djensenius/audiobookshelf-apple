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

        #expect(AccessTokenExpiry.date(of: token) == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func coversEveryPaddingRemainder() {
        let remainders = Set(
            ["", "x", "xx"].map { base64URL(#"{"exp":1700000000,"n":">>>?","p":"\#($0)"}"#).utf8.count % 4 })
        #expect(remainders == [0, 2, 3])
    }

    @Test func acceptsPaddedPayloadAndFractionalExp() {
        let payload = Data(#"{"exp":1700000000.5}"#.utf8).base64EncodedString()
        #expect(payload.hasSuffix("="))
        #expect(AccessTokenExpiry.date(of: "e30.\(payload).sig") == Date(timeIntervalSince1970: 1_700_000_000.5))
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
        makeJWT(claims: "[1700000000]"),
        "e30." + base64URL("not json") + ".sig",
    ])
    func unreadableTokensHaveUnknownExpiry(token: String) {
        #expect(AccessTokenExpiry.date(of: token) == nil)
    }
}
