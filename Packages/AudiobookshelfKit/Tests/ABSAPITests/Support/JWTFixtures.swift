import Foundation

/// Encodes `segment` as unpadded base64url, as JWTs do.
func base64URL(_ segment: String) -> String {
    Data(segment.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// An unsigned JWT-shaped token with `claims` (a JSON object) as its payload.
func makeJWT(claims: String) -> String {
    base64URL(#"{"alg":"HS256","typ":"JWT"}"#) + "." + base64URL(claims) + ".signature"
}

/// A JWT-shaped token that expires at `date`.
func makeJWT(expiringAt date: Date) -> String {
    makeJWT(claims: #"{"userId":"user-1","exp":\#(Int(date.timeIntervalSince1970))}"#)
}
