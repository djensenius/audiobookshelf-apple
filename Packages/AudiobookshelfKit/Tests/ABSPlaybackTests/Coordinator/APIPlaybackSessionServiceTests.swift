import ABSCore
import Foundation
import Testing

@testable import ABSAPI
@testable import ABSPlayback

private struct StaticTokens: TokenProvider {
    let value: ABSAPI.AuthTokens?

    func tokens() async -> ABSAPI.AuthTokens? { value }
    func replaceTokens(expected: ABSAPI.AuthTokens, with new: ABSAPI.AuthTokens) async -> Bool { false }
    func expireSession(ifCurrent rejected: ABSAPI.AuthTokens) async -> Bool { false }
}

private struct StaticDevice: DeviceIdentifying {
    func deviceIdentifier() async -> String { "device" }
}

struct APIPlaybackSessionServiceTests {
    private func service(
        version: ServerVersion = ServerVersion(2, 26, 2), customHeaders: [String: String] = [:],
        tokens: ABSAPI.AuthTokens? = ABSAPI.AuthTokens(accessToken: "a+b", refreshToken: "r")
    ) throws -> APIPlaybackSessionService {
        let configuration = try APIClientConfiguration(
            baseURL: try #require(URL(string: "https://abs.example/abs")), customHeaders: customHeaders)
        let provider = StaticTokens(value: tokens)
        return APIPlaybackSessionService(
            serverConnectionID: UUID(), client: APIClient(configuration: configuration, tokenProvider: provider),
            tokenProvider: provider, features: ServerFeatures(version: version), deviceIdentifiers: StaticDevice())
    }

    private func episodeSession(index: Int?) -> PlaybackSession {
        PlaybackSession(
            id: "sess", libraryItemId: "li-9", episodeId: "ep-1", mediaType: .podcast, duration: 1200,
            playMethod: .directPlay,
            audioTracks: [
                AudioTrack(
                    index: index, startOffset: 0, duration: 1200, contentUrl: "/api/items/li-9/file/77",
                    mimeType: "audio/mpeg")
            ])
    }

    @Test func sessionTracksUseTheirURLs() async throws {
        let stream = try await service(version: ServerVersion(2, 37, 0)).resolveStream(for: episodeSession(index: 1))
        #expect(stream.urls.map(\.absoluteString) == ["https://abs.example/abs/public/session/sess/track/1"])
        #expect(stream.plan.kind == .directPlay)
    }

    @Test func tokenFallbackAddsTheAccessToken() async throws {
        let stream = try await service().resolveStream(for: episodeSession(index: nil))
        #expect(stream.urls.map(\.absoluteString) == ["https://abs.example/abs/api/items/li-9/file/77?token=a%2Bb"])
    }

    @Test func tokenFallbackWithoutTokensFails() async throws {
        let service = try service(tokens: nil)
        await #expect(throws: StreamResolutionError.missingAccessToken) {
            try await service.resolveStream(for: episodeSession(index: nil))
        }
    }

    @Test func customHeadersNeedTheMissingTransport() async throws {
        let service = try service(version: ServerVersion(2, 37, 0), customHeaders: ["X-Proxy": "1"])
        await #expect(throws: StreamResolutionError.customHeaderTransportUnavailable) {
            try await service.resolveStream(for: episodeSession(index: 1))
        }
    }

    @Test func resolutionErrorsAreWrapped() async throws {
        let service = try service()
        let session = PlaybackSession(id: "sess", libraryItemId: "li", mediaType: .book, playMethod: .directPlay)
        await #expect(throws: StreamResolutionError.resolution(.noTracks)) {
            try await service.resolveStream(for: session)
        }
    }
}
