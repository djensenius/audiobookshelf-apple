import ABSCore
import Foundation
import Testing

@testable import ABSAPI

private func configuration(customHeaders: [String: String] = [:]) throws -> APIClientConfiguration {
    try APIClientConfiguration(
        baseURL: try #require(URL(string: "https://abs.example/abs")), customHeaders: customHeaders)
}

private let current = ServerFeatures(version: ServerVersion(2, 37, 2))
private let beforeNullIndexFix = ServerFeatures(version: ServerVersion(2, 26, 2))

private func episodeSession(index: Int?, contentUrl: String? = "/api/items/li-9/file/77%2F8") -> PlaybackSession {
    PlaybackSession(
        id: "sess-ep", libraryItemId: "li-9", episodeId: "ep-1", mediaType: .podcast, duration: 1200,
        playMethod: .directPlay,
        audioTracks: [
            AudioTrack(index: index, startOffset: 0, duration: 1200, contentUrl: contentUrl, mimeType: "audio/mpeg")
        ])
}

private func hlsSession(contentUrl: String? = "/hls/sess-hls/output.m3u8") -> PlaybackSession {
    PlaybackSession(
        id: "sess-hls", libraryItemId: "li-1", mediaType: .book, duration: 5400, playMethod: .transcode,
        audioTracks: [
            AudioTrack(
                index: 1, startOffset: 0, duration: 5400, contentUrl: contentUrl,
                mimeType: "application/vnd.apple.mpegurl")
        ])
}

@Suite struct TrackURLResolverTests {
    @Test func directPlayMultiTrackUsesPublicSessionRoutes() throws {
        let session = try decodeMultiTrackSession()
        let plan = try TrackURLResolver.resolve(session: session, features: current, configuration: configuration())

        #expect(plan.kind == .directPlay)
        #expect(plan.transport == .urlAsset)
        let base = "https://abs.example/abs/public/session/3f2b8e4c-9d1a-4c6e-8f00-1a2b3c4d5e6f/track"
        #expect(plan.tracks.map(\.url.absoluteString) == ["\(base)/1", "\(base)/2", "\(base)/3"])
        #expect(plan.tracks.map(\.mimeType) == ["audio/mpeg", "audio/mpeg", "audio/mpeg"])
        #expect(plan.tracks.map(\.startOffset) == [0, 1800.5, 4000.25])
        #expect(plan.tracks.map(\.duration) == [1800.5, 2199.75, 1400.5])
        #expect(plan.tracks.allSatisfy { $0.authentication == .session })
        #expect(plan.tracks.allSatisfy { $0.url.query() == nil })
        #expect(plan.tracks.allSatisfy { $0.authorizedURL(accessToken: "secret") == $0.url })
    }

    @Test func sessionIDIsOnePathSegment() throws {
        let session = PlaybackSession(
            id: "a/../b?c", libraryItemId: "li", mediaType: .book, playMethod: .directPlay,
            audioTracks: [AudioTrack(index: 1, duration: 1)])
        let plan = try TrackURLResolver.resolve(session: session, features: current, configuration: configuration())
        #expect(
            plan.tracks[0].url.absoluteString == "https://abs.example/abs/public/session/a%2F..%2Fb%3Fc/track/1")
    }

    @Test func nullIndexEpisodeUsesIndexZeroFrom2_26_3() throws {
        for version in [ServerVersion(2, 26, 3), ServerVersion(2, 37, 2)] {
            let plan = try TrackURLResolver.resolve(
                session: episodeSession(index: nil), features: ServerFeatures(version: version),
                configuration: configuration())
            #expect(plan.tracks[0].url.absoluteString == "https://abs.example/abs/public/session/sess-ep/track/0")
            #expect(plan.tracks[0].authentication == .session)
        }
    }

    @Test func nullIndexEpisodeBefore2_26_3UsesTokenFileFallback() throws {
        let plan = try TrackURLResolver.resolve(
            session: episodeSession(index: nil), features: beforeNullIndexFix, configuration: configuration())

        #expect(plan.kind == .directPlay)
        let track = try #require(plan.tracks.first)
        #expect(track.authentication == .accessTokenQuery)
        #expect(track.mimeType == "audio/mpeg")
        // The resolved URL itself never carries the token.
        #expect(track.url.absoluteString == "https://abs.example/abs/api/items/li-9/file/77%2F8")
        #expect(
            track.authorizedURL(accessToken: "a+b/c")?.absoluteString
                == "https://abs.example/abs/api/items/li-9/file/77%2F8?token=a%2Bb/c")
    }

    @Test func indexedEpisodeBefore2_26_3StaysOnPublicRoute() throws {
        let plan = try TrackURLResolver.resolve(
            session: episodeSession(index: 1), features: beforeNullIndexFix, configuration: configuration())
        #expect(plan.tracks[0].url.absoluteString == "https://abs.example/abs/public/session/sess-ep/track/1")
        #expect(plan.tracks[0].authentication == .session)
    }

    @Test func nullIndexBookTrackNeverUsesTokenFallback() throws {
        let session = PlaybackSession(
            id: "s", libraryItemId: "li", mediaType: .book, playMethod: .directPlay,
            audioTracks: [AudioTrack(index: nil, duration: 1, contentUrl: "/api/items/li/file/1")])
        let plan = try TrackURLResolver.resolve(
            session: session, features: beforeNullIndexFix, configuration: configuration())
        #expect(plan.tracks[0].url.absoluteString == "https://abs.example/abs/public/session/s/track/0")
        #expect(plan.tracks[0].authentication == .session)
    }

    @Test(arguments: [nil, "/hls/x/output.m3u8", "/api/items/li-9/file/"])
    func tokenFallbackWithoutInodeFails(contentUrl: String?) throws {
        #expect(throws: TrackURLResolutionError.missingFileReference) {
            try TrackURLResolver.resolve(
                session: episodeSession(index: nil, contentUrl: contentUrl), features: beforeNullIndexFix,
                configuration: configuration())
        }
    }

    @Test func transcodeUsesHLSPlaylistWithoutCredentials() throws {
        let plan = try TrackURLResolver.resolve(
            session: hlsSession(), features: current, configuration: configuration())
        #expect(plan.kind == .hls)
        #expect(plan.transport == .urlAsset)
        let track = try #require(plan.tracks.first)
        #expect(plan.tracks.count == 1)
        #expect(track.url.absoluteString == "https://abs.example/abs/hls/sess-hls/output.m3u8")
        #expect(track.mimeType == nil)
        #expect(track.duration == 5400)
        #expect(track.authentication == .session)
        #expect(track.authorizedURL(accessToken: "secret") == track.url)
    }

    @Test(arguments: [nil, "", "hls/x/output.m3u8", "//evil.example/hls/x.m3u8", "https://evil.example/x.m3u8"])
    func transcodeRejectsMissingOrAbsoluteContentURL(contentUrl: String?) throws {
        #expect(throws: TrackURLResolutionError.invalidContentURL) {
            try TrackURLResolver.resolve(
                session: hlsSession(contentUrl: contentUrl), features: current, configuration: configuration())
        }
    }

    @Test func customHeadersUseResourceLoaderForDirectPlay() throws {
        let plan = try TrackURLResolver.resolve(
            session: try decodeMultiTrackSession(), features: current,
            configuration: configuration(customHeaders: ["CF-Access-Client-Id": "id"]))
        #expect(plan.kind == .directPlay)
        #expect(plan.transport == .customHeaderResourceLoader)
        #expect(plan.tracks.allSatisfy { $0.url.scheme == "https" && $0.url.query() == nil })
    }

    @Test func customHeadersWithTranscodeFail() throws {
        #expect(throws: TrackURLResolutionError.transcodeUnavailableWithCustomHeaders) {
            try TrackURLResolver.resolve(
                session: hlsSession(), features: current,
                configuration: configuration(customHeaders: ["CF-Access-Client-Id": "id"]))
        }
    }

    @Test func unsupportedServerFails() throws {
        #expect(throws: TrackURLResolutionError.unsupportedServer(ServerVersion(2, 25, 1))) {
            try TrackURLResolver.resolve(
                session: try decodeMultiTrackSession(), features: ServerFeatures(version: ServerVersion(2, 25, 1)),
                configuration: configuration())
        }
    }

    @Test(arguments: [PlayMethod.directStream, .local, .unknown(9)])
    func nonStreamingPlayMethodsFail(method: PlayMethod) throws {
        let session = PlaybackSession(
            id: "s", libraryItemId: "li", mediaType: .book, playMethod: method,
            audioTracks: [AudioTrack(index: 1, duration: 1)])
        #expect(throws: TrackURLResolutionError.unsupportedPlayMethod(method)) {
            try TrackURLResolver.resolve(session: session, features: current, configuration: configuration())
        }
    }

    @Test func sessionWithoutTracksFails() throws {
        let session = PlaybackSession(id: "s", libraryItemId: "li", mediaType: .book, playMethod: .directPlay)
        #expect(throws: TrackURLResolutionError.noTracks) {
            try TrackURLResolver.resolve(session: session, features: current, configuration: configuration())
        }
    }
}
