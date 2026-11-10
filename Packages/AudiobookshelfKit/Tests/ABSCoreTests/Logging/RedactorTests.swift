import ABSCore
import Foundation
import Testing

/// Base64url without padding, as used in JWTs.
private func base64URL(_ json: String) -> String {
    Data(json.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

@Suite struct RedactorTests {
    @Test func redactsBearerTokens() {
        #expect(Log.redact("Authorization: Bearer abc.def-123") == "Authorization: Bearer <redacted>")
        #expect(Log.redact("authorization=bearer xyz, next") == "authorization=bearer <redacted>, next")
    }

    @Test(arguments: [
        "token", "access_token", "refresh_token", "accessToken", "refreshToken", "TOKEN", "code", "code_verifier",
    ])
    func redactsTokenQueryValues(name: String) {
        let url = "https://abs.example.com/api/items/1/cover?\(name)=s3cret&width=400#top"
        #expect(Log.redact(url) == "https://abs.example.com/api/items/1/cover?\(name)=<redacted>&width=400#top")
    }

    @Test func redactsTokenAfterOtherQueryItems() {
        #expect(Log.redact("/hls/a.m3u8?x=1&token=abc def") == "/hls/a.m3u8?x=1&token=<redacted> def")
    }

    @Test func keepsQueryItemsThatOnlyEndInToken() {
        let text = "/api/me?mytoken=abc&tokenize=1"
        #expect(Log.redact(text) == text)
    }

    @Test func redactsBareJWTs() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJ1c2VySWQiOiIxIn0.c2lnbmF0dXJl"
        #expect(Log.redact(#"{"accessToken":"\#(jwt)"}"#) == #"{"accessToken":"<redacted>"}"#)
    }

    @Test func redactsCustomHeaderValues() {
        let redactor = Redactor(secrets: ["cf-secret", "cf-secret-long", ""])
        #expect(
            redactor.redact("CF-Access-Client-Secret: cf-secret-long; other cf-secret")
                == "CF-Access-Client-Secret: <redacted>; other <redacted>"
        )
    }

    @Test func leavesOrdinaryTextAlone() {
        let text = "Loaded 12 items from library lib_1 in 0.4s"
        #expect(Log.redact(text) == text)
    }

    @Test func redactsTokenParametersAtStartOfTextOrAfterWhitespace() {
        #expect(Log.redact("token=abc&x=1") == "token=<redacted>&x=1")
        #expect(
            Log.redact("exchanging code=xyz code_verifier=pkce")
                == "exchanging code=<redacted> code_verifier=<redacted>")
        #expect(Log.redact("line one\ntoken=abc") == "line one\ntoken=<redacted>")
    }

    @Test func keepsParametersThatOnlyEndInCode() {
        let text = "/callback?errorcode=7&zipcode=12345"
        #expect(Log.redact(text) == text)
    }

    @Test func redactsJSONPasswords() {
        #expect(
            Log.redact(#"{"username":"root","password" : "hunter2"}"#)
                == #"{"username":"root","password" : "<redacted>"}"#
        )
    }

    @Test func keepsHostnamesThatLookLikeJWTPrefixes() {
        for text in ["https://eyjafjallajokull.example.com/api", "EYJabcd.efgh.ijkl", "eyJa.b.c"] {
            #expect(Log.redact(text) == text)
        }
    }

    @Test func ignoresShortSecrets() {
        #expect(Redactor(secrets: ["abc"]).redact("abc def") == "abc def")
        #expect(Redactor(secrets: ["abcd"]).redact("abcd def") == "<redacted> def")
    }

    @Test func descriptionsHideSecrets() {
        let redactor = Redactor(secrets: ["hunter2-secret"])
        for text in [
            String(describing: redactor), String(reflecting: redactor), "\(redactor)",
            String(describing: Mirror(reflecting: redactor).children.map(\.value)),
        ] {
            #expect(!text.contains("hunter2-secret"))
        }
    }

    @Test func customSecretsDoNotDisableBuiltInRules() {
        #expect(Redactor(secrets: ["pass"]).redact(#"{"password":"hunter2"}"#) == #"{"<redacted>word":"<redacted>"}"#)
        #expect(Redactor(secrets: ["token"]).redact("/a?token=abc") == "/a?<redacted>=<redacted>")
    }

    @Test func mergesOverlappingAndAdjacentRanges() {
        #expect(Redactor(secrets: ["abcdef", "defghi"]).redact("xabcdefghiy") == "x<redacted>y")
        #expect(Redactor(secrets: ["abcd", "efgh"]).redact("abcdefgh") == "<redacted>")
        #expect(Redactor(secrets: ["s3cret"]).redact("?token=s3cret&s3cret") == "?token=<redacted>&<redacted>")
    }

    @Test func redactsJSONPasswordsWithEscapedQuotes() {
        #expect(
            Log.redact(#"{"password":"prefix\"suffixsecret","next":1}"#) == #"{"password":"<redacted>","next":1}"#
        )
    }

    @Test func redactsJWTWithWhitespacePrefixedHeader() {
        let jwt = "\(base64URL(#"{ "alg":"HS256"}"#)).\(base64URL(#"{"sub":"1"}"#)).c2lnbmF0dXJl"
        #expect(jwt.hasPrefix("eyAi"))
        #expect(Log.redact("token: \(jwt).") == "token: <redacted>.")
    }

    @Test func redactsJWTWithEmptyClaimsAndNoSignature() {
        let jwt = "\(base64URL(#"{"alg":"none"}"#)).\(base64URL("{}"))."
        #expect(jwt.contains(".e30."))
        #expect(Log.redact("saw \(jwt) here") == "saw <redacted> here")
    }

    @Test func keepsDottedTextThatIsNotAJWT() {
        let noAlg = "\(base64URL(#"{"typ":"JWT"}"#)).\(base64URL("{}")).c2ln"
        let arrayClaims = "\(base64URL(#"{"alg":"HS256"}"#)).\(base64URL("[1]")).c2ln"
        for text in [
            "api.example.com", "a.b.c", "1.2.3", "v27.0.1-beta", "cdn.eu.api.example.com",
            "see README.md.txt now", noAlg, arrayClaims,
        ] {
            #expect(Log.redact(text) == text)
        }
    }

    @Test func redactsOverlappingSecretOccurrences() {
        #expect(Redactor(secrets: ["abcdea"]).redact("abcdeabcdea") == "<redacted>")
        // "aa" is below the minimum secret length, so use a 4-character self-overlapping secret.
        #expect(Redactor(secrets: ["aaaa"]).redact("xaaaaaay") == "x<redacted>y")
    }

    @Test(arguments: ["'opaque-secret'", "a!b*c(d)e~f$g,h;i:j@k/l?m", "(paren)"])
    func redactsQueryValuesWithReservedCharacters(value: String) {
        #expect(Log.redact("/cb?code=\(value)&state=ok") == "/cb?code=<redacted>&state=ok")
    }

    @Test func keepsDelimitersAroundURLs() {
        #expect(
            Log.redact(#"open "https://a.example/x?token=abc" now"#)
                == #"open "https://a.example/x?token=<redacted>" now"#)
        #expect(Log.redact("see <https://a.example/x?token=abc>.") == "see <https://a.example/x?token=<redacted>>.")
        #expect(Log.redact("/x?token=abc#frag") == "/x?token=<redacted>#frag")
    }
}
