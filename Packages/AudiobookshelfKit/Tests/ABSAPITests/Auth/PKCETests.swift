import Testing

@testable import ABSAPI

@Suite struct PKCETests {
    @Test func rfc7636AppendixBVector() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(PKCE.method == "S256")
    }

    @Test func challengeIsUnpaddedBase64URL() {
        for _ in 0..<50 {
            let challenge = PKCE().challenge
            // SHA-256 is 32 bytes: 43 base64url characters without padding.
            #expect(challenge.count == 43)
            #expect(!challenge.contains { "+/=".contains($0) })
        }
    }

    @Test func randomVerifierLengthAndCharacters() {
        let allowed = Set(PKCE.verifierCharacters)
        #expect(allowed.count == 66)
        var verifiers: Set<String> = []
        for _ in 0..<50 {
            let verifier = PKCE().verifier
            #expect(PKCE.verifierLengths.contains(verifier.count))
            #expect(verifier.allSatisfy(allowed.contains))
            verifiers.insert(verifier)
        }
        #expect(verifiers.count == 50)

        var generator = SystemRandomNumberGenerator()
        #expect(PKCE.randomVerifier(length: 43, using: &generator).count == 43)
        #expect(PKCE.randomVerifier(length: 128, using: &generator).count == 128)
    }

    @Test func descriptionRedactsVerifier() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(!String(describing: pkce).contains(pkce.verifier))
        #expect(!String(reflecting: pkce).contains(pkce.verifier))
        var dumped = ""
        dump(pkce, to: &dumped)
        #expect(!dumped.contains(pkce.verifier))
    }
}
