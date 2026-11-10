import ABSCore
import Foundation

/// How a resolved track URL is authorised (ADR 0007).
public enum TrackAuthentication: Sendable, Hashable {
    /// The URL is a session capability (`/public/session/…` or `/hls/…`) and carries no user
    /// credential. It works only while the session is open.
    case session
    /// The URL is `/api/items/:id/file/:ino` and needs the access token as `?token=`. Refresh the
    /// token, then build the asset with ``PlayableTrack/authorizedURL(accessToken:)`` right
    /// before creating the player item. Only used for null-index podcast episode tracks on
    /// servers below 2.26.3; the URL stops working when the token expires (1 hour by default).
    case accessTokenQuery
}

/// One `AVURLAsset` to create, in play order.
public struct PlayableTrack: Sendable, Hashable {
    /// Never logged at info level: it is a capability for the session's audio. Never contains a
    /// token; see ``authorizedURL(accessToken:)``.
    public let url: URL
    /// The value for `AVURLAssetOverrideMIMETypeKey`, or `nil` for HLS (the playlist URL has an
    /// `.m3u8` extension).
    public let mimeType: String?
    /// Seconds from the start of the media.
    public let startOffset: Double
    public let duration: Double
    public let authentication: TrackAuthentication

    /// The URL to give `AVURLAsset`. Adds `token` only for ``TrackAuthentication/accessTokenQuery``.
    public func authorizedURL(accessToken: String) -> URL? {
        guard authentication == .accessTokenQuery else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "token", value: accessToken)]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}

/// The playable URLs for a streaming session and how to load them.
public struct StreamPlan: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// One item per track, in an `AVQueuePlayer`.
        case directPlay
        /// A single HLS playlist covering the whole media.
        case hls
    }

    public enum Transport: Sendable, Hashable {
        /// A plain `AVURLAsset`.
        case urlAsset
        /// A custom-scheme `AVAssetResourceLoaderDelegate` that adds the connection's custom
        /// headers (never `Authorization` or `Cookie`) to every request.
        case customHeaderResourceLoader
    }

    public let kind: Kind
    public let transport: Transport
    public let tracks: [PlayableTrack]
}

public enum TrackURLResolutionError: Error, Sendable, Hashable {
    /// The server is below ``ServerFeatures/minimumSupported``.
    case unsupportedServer(ServerVersion)
    /// The session is local or uses a play method this client doesn't stream.
    case unsupportedPlayMethod(PlayMethod)
    case noTracks
    /// The server chose HLS, which can't carry the connection's custom headers.
    case transcodeUnavailableWithCustomHeaders
    /// A URL couldn't be built, or the HLS track's `contentUrl` isn't `/hls/<session id>/output.m3u8`.
    case invalidContentURL
    /// The token fallback needs the file inode, which the track's `contentUrl` doesn't contain.
    case missingFileReference
}

/// Turns a streaming ``PlaybackSession`` into playable URLs (ADR 0007, decisions 1–3 and 6).
///
/// - Direct play (`playMethod` 0): `<server>/public/session/{id}/track/{index ?? 0}` per track,
///   with the track's MIME type as an override. Below 2.26.3, a podcast episode track with a
///   `null` index can't be addressed that way and uses `/api/items/{id}/file/{ino}` with
///   ``TrackAuthentication/accessTokenQuery`` instead.
/// - Transcode (`playMethod` 2): `<server>/hls/{id}/output.m3u8`, the session's HLS playlist,
///   with no credentials, after checking that `audioTracks[0].contentUrl` is exactly that path. Not available when the connection has custom headers.
///
/// Never uses `AVURLAssetHTTPHeaderFieldsKey`; the engine creates plain `AVURLAsset`s, or uses
/// the resource loader when ``StreamPlan/transport`` says so.
public enum TrackURLResolver {
    public static func resolve(
        session: PlaybackSession, features: ServerFeatures, configuration: APIClientConfiguration
    ) throws(TrackURLResolutionError) -> StreamPlan {
        guard features.isSupported else { throw .unsupportedServer(features.version) }
        guard let first = session.audioTracks.first else { throw .noTracks }
        let usesCustomHeaders = !configuration.customHeaders.isEmpty
        let base = configuration.baseURL

        switch session.playMethod {
        case .directPlay:
            var tracks: [PlayableTrack] = []
            for track in session.audioTracks {
                tracks.append(try directPlayTrack(track, session: session, features: features, base: base))
            }
            return StreamPlan(
                kind: .directPlay, transport: usesCustomHeaders ? .customHeaderResourceLoader : .urlAsset,
                tracks: tracks)
        case .transcode:
            guard !usesCustomHeaders else { throw .transcodeUnavailableWithCustomHeaders }
            // The server always sends this exact path; anything else could leave the base path.
            let path = "/hls/\(pathSegment(session.id))/output.m3u8"
            guard first.contentUrl == path else { throw .invalidContentURL }
            let track = PlayableTrack(
                url: try url(base: base, path: path), mimeType: nil, startOffset: 0, duration: first.duration,
                authentication: .session)
            return StreamPlan(kind: .hls, transport: .urlAsset, tracks: [track])
        case .directStream, .local, .unknown:
            throw .unsupportedPlayMethod(session.playMethod)
        }
    }

    private static func directPlayTrack(
        _ track: AudioTrack, session: PlaybackSession, features: ServerFeatures, base: URL
    ) throws(TrackURLResolutionError) -> PlayableTrack {
        let isEpisode = session.mediaType == .podcast || session.episodeId != nil
        let path: String
        let authentication: TrackAuthentication
        if isEpisode, features.requiresTokenFallback(forEpisodeTrackIndex: track.index) {
            guard let ino = fileInode(from: track.contentUrl) else { throw .missingFileReference }
            path = "/api/items/\(pathSegment(session.libraryItemId))/file/\(pathSegment(ino))"
            authentication = .accessTokenQuery
        } else {
            // Never interpolate a nil index: the route answers 400 for "null".
            path = "/public/session/\(pathSegment(session.id))/track/\(track.index ?? 0)"
            authentication = .session
        }
        return PlayableTrack(
            url: try url(base: base, path: path), mimeType: track.mimeType, startOffset: track.startOffset ?? 0,
            duration: track.duration, authentication: authentication)
    }

    private static func url(base: URL, path: String) throws(TrackURLResolutionError) -> URL {
        guard let url = try? APIClient.url(base: base, path: path, query: []) else { throw .invalidContentURL }
        return url
    }

    /// The `:ino` of a direct-play `contentUrl` (`/api/items/:id/file/:ino`), percent-decoded.
    static func fileInode(from contentUrl: String?) -> String? {
        guard let contentUrl else { return nil }
        let path = contentUrl.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 2, segments[segments.count - 2] == "file" else { return nil }
        let raw = String(segments[segments.count - 1])
        let ino = raw.removingPercentEncoding ?? raw
        return ino.isEmpty ? nil : ino
    }
}

// Session ids are capabilities (ADR 0007): descriptions, debug output and mirrors never show them.
extension PlayableTrack: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The URL with the session id in `…/public/session/<id>/track/<n>` and `…/hls/<id>/output.m3u8`
    /// replaced, and without a query.
    public var redactedURL: String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "<redacted>" }
        var segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        // Match the route from the end, so a base path containing `hls` or `public` can't shift it.
        let count = segments.count
        if count >= 5, segments[count - 5] == "public", segments[count - 4] == "session",
            segments[count - 2] == "track"
        {
            segments[count - 3] = "<redacted>"
        } else if count >= 3, segments[count - 3] == "hls", segments[count - 1] == "output.m3u8" {
            segments[count - 2] = "<redacted>"
        }
        components.percentEncodedPath = ""
        components.percentEncodedQuery = nil
        return (components.string ?? "") + segments.joined(separator: "/")
    }

    public var description: String {
        "PlayableTrack(url: \(redactedURL), mimeType: \(mimeType ?? "nil"), startOffset: \(startOffset), "
            + "duration: \(duration), authentication: \(authentication))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "url": redactedURL, "mimeType": mimeType as Any, "startOffset": startOffset, "duration": duration,
                "authentication": authentication,
            ], displayStyle: .struct)
    }
}

extension StreamPlan: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "StreamPlan(kind: \(kind), transport: \(transport), tracks: [\(tracks.map(\.description).joined(separator: ", "))])"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["kind": kind, "transport": transport, "tracks": tracks], displayStyle: .struct)
    }
}
