import Foundation

/// The kind of server image (ADR 0005).
public enum ImageKind: String, Sendable, Hashable, Codable {
    /// `GET /api/items/:id/cover`.
    case itemCover
    /// `GET /api/authors/:id/image`.
    case authorImage
}

/// One of the fixed widths requested from the server, so it keeps at most three renditions
/// per image (ADR 0005).
public enum ImageWidthBucket: Int, Sendable, Hashable, Codable, CaseIterable {
    case small = 300
    case medium = 600
    case large = 1200

    /// The smallest bucket at least `pixelWidth` wide (displayed width × display scale), or
    /// ``large`` for anything wider.
    public init(pixelWidth: Double) {
        self = Self.allCases.first { Double($0.rawValue) >= pixelWidth } ?? .large
    }
}

/// The encoding requested from the server.
public enum ImageFormat: String, Sendable, Hashable, Codable {
    /// Used for every on-screen image.
    case webp
    /// Used for downloaded (offline) covers.
    case jpeg
}

/// What to load for an image (ADR 0005).
public enum ImageSource: Sendable, Hashable {
    /// An image served by the connected server. `updatedAt` is the entity's `updatedAt` in
    /// epoch milliseconds, sent as `ts`.
    case server(
        kind: ImageKind, entityID: String, updatedAt: Int?, width: ImageWidthBucket, format: ImageFormat = .webp)
    /// An absolute external URL, such as a legacy `coverPath` that is an `http(s)` URL.
    case external(URL)
}

/// Turns an ``ImageSource`` into a request for one server connection.
///
/// A builder belongs to a single server connection (in ABSAPI, one `MediaURLBuilder` per
/// connection), so `ImageSource` carries no server. Mapping an `ImageKey` to an `ImageSource`
/// is added by the image pipeline (#43) without changing this shape.
///
/// Implementations never add the Audiobookshelf access token: both image routes are
/// unauthenticated on every supported server. They send the connection's custom headers to
/// the server's origin only, and no cookies. An ``ImageSource/external(_:)`` URL is built only if
/// ``ImageDestination/isAllowed(_:server:)`` allows it for the connection's server.
public protocol ImageRequestBuilding: Sendable {
    /// Returns `nil` if no valid URL can be built.
    func imageRequest(for source: ImageSource) -> URLRequest?
}
