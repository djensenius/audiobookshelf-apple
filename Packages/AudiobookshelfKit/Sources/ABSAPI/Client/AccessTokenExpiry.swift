import Foundation

/// The `exp` and `iat` claims of a JWT access token, read only to schedule refreshes. The
/// signature isn't checked: the server still decides whether the token is valid. Times are
/// seconds since 1970 by the server's clock.
struct AccessTokenExpiry: Equatable {
    let expiresAt: TimeInterval
    let issuedAt: TimeInterval?

    init(expiresAt: TimeInterval, issuedAt: TimeInterval?) {
        self.expiresAt = expiresAt
        self.issuedAt = issuedAt
    }

    /// `nil` if the expiry is unknown: not a JWT, or no finite numeric `exp`. An unreadable `iat`
    /// is ignored. The payload is decoded as base64url with optional padding; the standard
    /// alphabet's `+` and `/` are accepted too.
    init?(token: String) {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, let payload = Self.decode(base64URL: segments[1]),
            let claims = try? JSONDecoder().decode(Claims.self, from: payload)
        else { return nil }
        expiresAt = claims.exp
        issuedAt = claims.iat
    }

    private struct Claims: Decodable {
        let exp: TimeInterval
        let iat: TimeInterval?

        private enum CodingKeys: String, CodingKey {
            case exp, iat
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            exp = try container.decode(TimeInterval.self, forKey: .exp)
            guard exp.isFinite else {
                throw DecodingError.dataCorruptedError(forKey: .exp, in: container, debugDescription: "Not finite")
            }
            let iat = try? container.decodeIfPresent(TimeInterval.self, forKey: .iat)
            self.iat = iat.flatMap { $0.isFinite ? $0 : nil }
        }
    }

    /// Decodes a base64url segment with optional padding.
    private static func decode(base64URL segment: Substring) -> Data? {
        guard segment.utf8.count <= maximumSegmentLength, segment.utf8.count % 4 != 1 else { return nil }
        var base64 = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    static let maximumSegmentLength = 16_384
}
