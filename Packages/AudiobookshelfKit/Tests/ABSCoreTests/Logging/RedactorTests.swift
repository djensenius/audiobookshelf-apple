import ABSCore
import Testing

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
}
