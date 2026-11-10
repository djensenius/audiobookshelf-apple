import Foundation

/// Reads the `exp` claim of a JWT access token, only to schedule refreshes. The signature isn't
/// checked: the server still decides whether the token is valid.
enum AccessTokenExpiry {
    /// When `token` expires, or `nil` if that's unknown (not a JWT, or no numeric `exp`).
    static func date(of token: String) -> Date? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, let payload = decode(base64URL: segments[1]) else { return nil }
        guard let claims = try? JSONDecoder().decode(Claims.self, from: payload),
            let exp = claims.exp, exp.isFinite
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private struct Claims: Decodable {
        let exp: Double?
    }

    /// Decodes a base64url segment with optional padding.
    private static func decode(base64URL segment: Substring) -> Data? {
        guard segment.utf8.count <= maximumSegmentLength, segment.utf8.count % 4 != 1 else { return nil }
        var base64 = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    private static let maximumSegmentLength = 16_384
}
