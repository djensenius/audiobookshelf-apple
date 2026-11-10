import ABSAPI
import ABSCore
import Foundation

/// ``PlaybackSessionService`` over one connection's ``APIClient`` (ADR 0007).
public struct APIPlaybackSessionService: PlaybackSessionService {
    public let serverConnectionID: UUID
    private let client: APIClient
    private let tokenProvider: any TokenProvider
    private let features: ServerFeatures
    private let deviceIdentifiers: any DeviceIdentifying

    public init(
        serverConnectionID: UUID, client: APIClient, tokenProvider: any TokenProvider, features: ServerFeatures,
        deviceIdentifiers: any DeviceIdentifying
    ) {
        self.serverConnectionID = serverConnectionID
        self.client = client
        self.tokenProvider = tokenProvider
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
                guard let token = await tokenProvider.tokens()?.accessToken,
                    let url = track.authorizedURL(accessToken: token)
                else { throw StreamResolutionError.missingAccessToken }
                urls.append(url)
            } else {
                urls.append(track.url)
            }
        }
        return ResolvedStream(plan: plan, urls: urls)
    }

    public func closeSession(id: String, report: PlaybackSyncReport?) async throws {
        _ = try await client.send(SessionEndpoints.close(sessionID: id, report: report))
    }
}
