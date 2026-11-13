import CryptoKit
import Foundation

/// Names an ``ImageKey``'s file in a ``CoverFileStore`` without the key's external URL, so it can
/// be persisted outside the app (the widget snapshot, #89) with no credential a signed cover URL
/// may carry. ``identity`` is a truncated SHA-256 digest of the entity ID and external URL,
/// the same one the file name ends with, so the URL can't be read back from it.
public struct CoverLocator: Sendable, Hashable, Codable {
    public var serverID: UUID
    public var kind: ImageKind
    public var entityID: String
    /// The entity's `updatedAt` in epoch milliseconds.
    public var updatedAt: Int?
    public var bucket: ImageWidthBucket
    /// 12 lowercase hex digits; see the type's description.
    public var identity: String

    public init(_ key: ImageKey) {
        serverID = key.serverID
        kind = key.kind
        entityID = key.entityID
        updatedAt = key.updatedAt
        bucket = key.bucket
        let digest = SHA256.hash(data: Data((key.entityID + "\n" + (key.externalURL?.absoluteString ?? "")).utf8))
        identity = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    public func with(bucket: ImageWidthBucket) -> CoverLocator {
        var locator = self
        locator.bucket = bucket
        return locator
    }

    /// `<kind>-<entityID>-<updatedAt>-<bucket>-<identity>`, the `CoverFileStore` file name without
    /// its extension. The entity ID keeps its first 64 Unicode scalars, each mapped to an ASCII
    /// letter, digit or `_`, so the stem is pure ASCII, at most 64 bytes of ID, and can't escape
    /// the server's folder or exceed the 255-byte file-name limit. The identity digest keeps
    /// sanitised names from colliding. A missing `updatedAt` is `n`, distinct from `0`. A decoded
    /// identity that isn't 12 hex digits is replaced by `_`, so it can't escape the folder either.
    var fileStem: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        let entity = String(
            String.UnicodeScalarView(
                entityID.unicodeScalars.prefix(64).map { $0.isASCII && allowed.contains($0) ? $0 : "_" }))
        let hex = identity.count == 12 && identity.allSatisfy(\.isHexDigit) ? identity : "_"
        let version = updatedAt.map(String.init) ?? "n"
        return "\(kind.rawValue)-\(entity)-\(version)-\(bucket.rawValue)-\(hex)"
    }
}
