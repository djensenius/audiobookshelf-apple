import ABSAPI
import ABSCore
import Foundation

/// ``PlaybackSessionService`` over one connection's ``APIClient`` (ADR 0007).
public struct APIPlaybackSessionService: PlaybackSessionService {
    public let serverConnectionID: UUID
    private let client: APIClient
    private let features: ServerFeatures
    private let deviceIdentifiers: any DeviceIdentifying

    public init(
        serverConnectionID: UUID, client: APIClient, features: ServerFeatures, deviceIdentifiers: any DeviceIdentifying
    ) {
        self.serverConnectionID = serverConnectionID
        self.client = client
        self.features = features
        self.deviceIdentifiers = deviceIdentifiers
    }

    public func startSession(itemID: String, episodeID: String?) async throws -> PlaybackSession {
        let request = await PlaybackDeviceInfo.startRequest(deviceIdentifiers: deviceIdentifiers)
        return try await client.send(SessionEndpoints.start(itemID: itemID, episodeID: episodeID, request: request))
    }

    public func mediaProgress(itemID: String, episodeID: String?) async throws -> MediaProgress? {
        try await client.mediaProgress(itemID: itemID, episodeID: episodeID)
    }

    /// A token-fallback track (``TrackAuthentication/accessTokenQuery``) gets its access token from
    /// ``APIClient/accessToken(replacing:)``, so one that is about to expire is refreshed first.
    ///
    /// - Throws: ``StreamResolutionError``, with ``StreamResolutionError/missingAccessToken`` when
    ///   the connection is signed out or the server ended its session; `CancellationError` when the
    ///   caller is cancelled, which isn't wrapped so it stays a cancellation; and the ``APIError``
    ///   when the token refresh fails otherwise (for example the stored token has expired and the
    ///   server is unreachable).
    public func resolveStream(for session: PlaybackSession) async throws -> ResolvedStream {
        let plan: StreamPlan
        do {
            plan = try TrackURLResolver.resolve(
                session: session, features: features, configuration: await client.configuration)
        } catch {
            throw StreamResolutionError.resolution(error)
        }
        guard plan.transport == .urlAsset else { throw StreamResolutionError.customHeaderTransportUnavailable }
        var urls: [URL] = []
        for track in plan.tracks {
            if track.authentication == .accessTokenQuery {
                let token = try await accessToken()
                guard let url = track.authorizedURL(accessToken: token) else {
                    throw StreamResolutionError.missingAccessToken
                }
                urls.append(url)
            } else {
                urls.append(track.url)
            }
        }
        return ResolvedStream(plan: plan, urls: urls)
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
}
