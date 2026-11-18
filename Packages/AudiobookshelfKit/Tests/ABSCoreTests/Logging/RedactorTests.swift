import ABSCore
import Foundation
import Testing

/// Base64url without padding, as used in JWTs.
private func base64URL(_ json: String) -> String {
    Data(json.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// The shape of the legacy, non-expiring token servers 2.26.0–2.28.x put in HLS segment URIs
/// (#662): a JWT with no `exp` claim.
private let legacyToken =
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VySWQiOiJ1MSIsInVzZXJuYW1lIjoicm9vdCIsImlhdCI6MTc1MjMwMDAwMH0"
    + ".c2lnbmF0dXJl"

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

    @Test(arguments: [
        "%74oken", "access%5Ftoken", "access%5ftoken", "TOKEN", "%54oKeN", "Refresh%5FToken", "%63%6F%64%65",
        "code%5Fverifier", "%2574oken",
    ])
    func redactsEncodedAndMixedCaseParameterNames(name: String) {
        #expect(Log.redact("/a?x=1&\(name)=s3cret&y=2") == "/a?x=1&\(name)=<redacted>&y=2")
        #expect(Log.redact("sent \(name)=s3cret") == "sent \(name)=<redacted>")
    }

    @Test(arguments: ["%", "%zz", "tok%en", "%E2%82", "%FF", "%252525252574oken"])
    func redactsMalformedOrDeeplyEncodedNames(name: String) {
        #expect(Log.redact("/a?\(name)=s3cret&y=2") == "/a?\(name)=<redacted>&y=2")
    }

    @Test func keepsOrdinaryEncodedParameterNames() {
        let text = "/a?sort%5Bfield%5D=title&q=caf%C3%A9&my%74oken=1"
        #expect(Log.redact(text) == text)
    }

    @Test func findsTokenPairsInsideOtherValues() {
        #expect(Log.redact("/a?a=1;token=s3cret") == "/a?a=1;token=<redacted>")
    }

    @Test func redactsNestedAndRepeatedSensitivePairs() {
        #expect(Log.redact("a=1;token=s3cret;b=2&c=3") == "a=1;token=<redacted>&c=3")
        #expect(Log.redact("token=a;code=b;x=1 next") == "token=<redacted> next")
        #expect(Log.redact("token=a&token=b") == "token=<redacted>&token=<redacted>")
    }

    // MARK: Stream URLs (#662)

    /// Opaque values are caught by the query rule alone, without the JWT rule's help.
    @Test(arguments: [legacyToken, "0paque-legacy-token"])
    func redactsHLSSegmentURLs(token: String) {
        #expect(
            Log.redact("GET https://abs.example/hls/abc/output-3.ts?token=\(token) failed")
                == "GET https://abs.example/hls/abc/output-3.ts?token=<redacted> failed")
    }

    @Test func redactsEveryURIInAnHLSPlaylist() {
        let playlist = """
            #EXTM3U
            #EXTINF:6.000000,
            output-0.ts?token=0paque-legacy-token
            #EXTINF:6.000000,
            output-1.ts?token=\(legacyToken)
            #EXT-X-ENDLIST
            """
        #expect(
            Log.redact(playlist) == """
                #EXTM3U
                #EXTINF:6.000000,
                output-0.ts?token=<redacted>
                #EXTINF:6.000000,
                output-1.ts?token=<redacted>
                #EXT-X-ENDLIST
                """)
    }

    /// The `?token=` direct-play fallback for null-index podcast episodes (#210), as
    /// `PlayableTrack.authorizedURL(accessToken:)` builds it.
    @Test(arguments: [legacyToken, "a%2Bb/c"])
    func redactsDirectPlayTokenFallbackURLs(token: String) {
        #expect(
            Log.redact("https://abs.example/abs/api/items/li-9/file/77%2F8?token=\(token)")
                == "https://abs.example/abs/api/items/li-9/file/77%2F8?token=<redacted>")
    }

    /// `String(describing:)` of a URL error lists the failing URL in its user info.
    @Test(arguments: [legacyToken, "0paque-legacy-token"])
    func redactsFailingStreamURLsInErrorDescriptions(token: String) throws {
        let url = try #require(URL(string: "https://abs.example/hls/abc/output-3.ts?token=\(token)"))
        let error = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url])
        let text = String(describing: error)
        #expect(text.contains(token))
        let redacted = Log.redact(text)
        #expect(!redacted.contains(token))
        #expect(redacted.contains("output-3.ts?token=<redacted>"))
    }

    /// ``Log/redacted(_:)`` is what public error logs interpolate (#662): an error's description
    /// can quote a failing URL or the server's response text.
    @Test func redactedErrorLosesTokensInItsDescription() throws {
        struct ServerFailure: Error { let message: String }
        let url = try #require(URL(string: "https://abs.example/api/me?token=0paque-legacy-token"))
        let urlError = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url])
        let serverFailure = ServerFailure(message: "proxy said Authorization: Bearer 0paque-bearer")
        for error in [urlError, serverFailure] as [any Error] {
            #expect(String(describing: error).contains("0paque"))
            #expect(!Log.redacted(error).contains("0paque"))
        }
        #expect(Log.redacted(urlError).contains("/api/me?token=<redacted>"))
        #expect(Log.redacted(serverFailure).contains("Bearer <redacted>"))
    }

    /// Redaction must stay linear: before this was fixed, each parameter rescanned the rest of the
    /// text, so these inputs took seconds. Each now takes milliseconds; the bound is generous.
    @Test(
        .timeLimit(.minutes(1)),
        arguments: [("x=1;", nil), ("?x=1&", nil), ("token=1;", "token=<redacted>")] as [(String, String?)]
    )
    func redactsLongParameterRunsInLinearTime(pair: String, expected: String?) {
        let text = String(repeating: pair, count: 100_000 / pair.utf8.count)
        var redacted = ""
        let elapsed = ContinuousClock().measure { redacted = Log.redact(text) }
        #expect(elapsed < .seconds(2))
        // `;` doesn't end a value, so the first `token=` value covers the rest of the run.
        #expect(redacted == (expected ?? text))
    }
}
