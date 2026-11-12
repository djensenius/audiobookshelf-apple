import ABSAPI
import ABSCore
import Foundation

/// ``PlaybackSessionService`` over one connection's ``APIClient`` (ADR 0007).
public struct APIPlaybackSessionService: PlaybackSessionService {
    public let serverConnectionID: UUID
    private let client: APIClient
    private let features: ServerFeatures
    private let deviceIdentifiers: any DeviceIdentifying
    private let streamingConfiguration: @Sendable () -> URLSessionConfiguration

    /// - Parameter streamingConfiguration: The base session configuration for a
    ///   ``HeaderStreamingTransport``, used when the connection has custom headers. Tests pass one
    ///   with a stub `URLProtocol`.
    public init(
        serverConnectionID: UUID, client: APIClient, features: ServerFeatures, deviceIdentifiers: any DeviceIdentifying,
        streamingConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }
    ) {
        self.serverConnectionID = serverConnectionID
        self.client = client
        self.features = features
        self.deviceIdentifiers = deviceIdentifiers
        self.streamingConfiguration = streamingConfiguration
    }

    public func startSession(itemID: String, episodeID: String?) async throws -> PlaybackSession {
        let request = await PlaybackDeviceInfo.startRequest(deviceIdentifiers: deviceIdentifiers)
        return try await client.send(SessionEndpoints.start(itemID: itemID, episodeID: episodeID, request: request))
    }

    public func mediaProgress(itemID: String, episodeID: String?) async throws -> MediaProgress? {
        try await client.mediaProgress(itemID: itemID, episodeID: episodeID)
    }

    /// Token-fallback tracks (``TrackAuthentication/accessTokenQuery``) share one access token from
    /// ``APIClient/accessToken(replacing:)``, so one that is about to expire is refreshed first.
    /// On a connection with custom headers the stream carries a new ``HeaderStreamingTransport``
    /// with those headers (ADR 0007 §6); a transcode session there fails to resolve.
    ///
    /// - Throws: ``StreamResolutionError``, with ``StreamResolutionError/missingAccessToken`` when
    ///   the connection is signed out or the server ended its session; `CancellationError` when the
    ///   caller is cancelled, which isn't wrapped so it stays a cancellation; and the ``APIError``
    ///   when the token refresh fails otherwise (for example the stored token has expired and the
    ///   server is unreachable).
    public func resolveStream(for session: PlaybackSession) async throws -> ResolvedStream {
        let plan: StreamPlan
        let configuration = await client.configuration
        do {
            plan = try TrackURLResolver.resolve(session: session, features: features, configuration: configuration)
        } catch {
            throw StreamResolutionError.resolution(error)
        }
        var urls: [URL] = []
        var streamToken: String?
        for track in plan.tracks {
            if track.authentication == .accessTokenQuery {
                // One token for every track, so the recorded token is the one each URL carries.
                let token: String
                if let streamToken {
                    token = streamToken
                } else {
                    token = try await accessToken()
                }
                streamToken = token
                guard let url = track.authorizedURL(accessToken: token) else {
                    throw StreamResolutionError.missingAccessToken
                }
                urls.append(url)
            } else {
                urls.append(track.url)
            }
        }
        let transport: HeaderStreamingTransport? =
            switch plan.transport {
            case .urlAsset: nil
            case .customHeaderResourceLoader:
                HeaderStreamingTransport(
                    customHeaders: configuration.customHeaders, configuration: streamingConfiguration())
            }
        return ResolvedStream(plan: plan, urls: urls, transport: transport, accessToken: streamToken)
    }

    /// A token for a URL the player loads outside the client; no tokens, or a session the server
    /// rejected, is ``StreamResolutionError/missingAccessToken``. Anything else propagates.
    private func accessToken() async throws -> String {
        do {
            return try await client.accessToken(replacing: nil)
        } catch APIError.notAuthenticated, APIError.sessionExpired {
            throw StreamResolutionError.missingAccessToken
        }
    }

    public func closeSession(id: String, report: PlaybackSyncReport?) async throws {
        _ = try await client.send(SessionEndpoints.close(sessionID: id, report: report))
    }

    /// Replaces `rejected` (else the stored token) through the client's single-flight refresh; a
    /// token another caller already replaced isn't refreshed again. ``APIError/notAuthenticated``
    /// when signed out.
    public func refreshStreamAccess(replacing rejected: String?) async throws {
        var token = rejected
        if token == nil { token = await client.currentAccessToken() }
        guard let token else { throw APIError.notAuthenticated }
        _ = try await client.accessToken(replacing: token)
    }
}
