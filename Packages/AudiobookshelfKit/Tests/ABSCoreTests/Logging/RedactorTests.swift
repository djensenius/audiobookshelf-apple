import ABSCore
import Testing

@Suite struct RedactorTests {
    @Test func redactsBearerTokens() {
        #expect(Log.redact("Authorization: Bearer abc.def-123") == "Authorization: Bearer <redacted>")
        #expect(Log.redact("authorization=bearer xyz, next") == "authorization=bearer <redacted>, next")
    }

    @Test(arguments: ["token", "access_token", "refresh_token", "accessToken", "refreshToken", "TOKEN"])
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
}
