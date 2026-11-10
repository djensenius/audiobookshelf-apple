/// Version gates for a connected server (ADR 0007). All version checks go through this type.
public struct ServerFeatures: Sendable, Hashable {
    /// The oldest server the app can sign in to.
    public static let minimumSupported = ServerVersion(2, 26, 0)

    /// From this version the public session track route accepts index `0` for podcast
    /// episode tracks whose `index` is `null` (episodes created before 2.21.0).
    public static let nullIndexEpisodeTrackRoute = ServerVersion(2, 26, 3)

    public let version: ServerVersion

    public init(version: ServerVersion) {
        self.version = version
    }

    /// Returns `nil` when `serverVersion` can't be parsed; callers treat that as unsupported.
    public init?(serverVersion: String) {
        guard let version = ServerVersion(serverVersion) else { return nil }
        self.init(version: version)
    }

    /// Whether the app can sign in to and use this server.
    public var isSupported: Bool { version >= Self.minimumSupported }

    /// Whether a podcast episode track with a `null` index can be played via the public
    /// session track route.
    public var supportsNullIndexEpisodeTracks: Bool { version >= Self.nullIndexEpisodeTrackRoute }

    /// Whether a podcast episode track with this `index` must use the `?token=` file URL
    /// fallback instead of the public session track route. Remove when `minimumSupported`
    /// reaches 2.26.3.
    public func requiresTokenFallback(forEpisodeTrackIndex index: Int?) -> Bool {
        index == nil && !supportsNullIndexEpisodeTracks
    }
}
