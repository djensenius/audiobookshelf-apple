import ABSAPI
import ABSCore
import ABSPlayback
import Foundation
import Testing

// The server half of ADR 0007's streaming results matrix (#48): how each pinned release (tags
// v2.26.0 and v2.37.2 of advplyr/audiobookshelf) answers the app's production play request for
// each format. `PlaybackSessionManager.startSession` direct plays only when every file's MIME
// type is in `supportedMimeTypes` (`server/managers/PlaybackSessionManager.js` L321,
// `Book.checkCanDirectPlay` in `server/models/Book.js`); `.opus` is `audio/ogg`
// (`server/utils/constants.js` L43), which the app denies, so an Opus book is transcoded to HLS
// (`server/objects/Stream.js`). Playback on devices stays a manual check (#49).

extension Trait where Self == ConditionTrait {
    /// The Opus and FLAC books are in a third library, which other suites don't expect, so
    /// `scripts/test-server.sh` adds it and runs this suite last, with `ABS_STREAMING_CONTRACT=1`.
    static var streamingFormatPass: Self {
        .enabled(
            if: ProcessInfo.processInfo.environment["ABS_STREAMING_CONTRACT"] == "1",
            "Runs in the streaming format pass of scripts/test-server.sh (docs/testing/server-contracts.md)")
    }
}

extension ContractServer {
    /// Whether HLS playlists add `?token=` with the user's legacy, non-expiring token to every
    /// segment URI. 2.26.0 does (`server/utils/generators/hlsPlaylistGenerator.js` L21 and L25,
    /// fed `user.token` by `Stream.generatePlaylist`); 2.37.2 lists bare `output-N.ts`. `nil` for
    /// other servers, where only the segment paths are checked.
    var hlsSegmentsCarryUserToken: Bool? {
        switch version {
        case "2.26.0": true
        case "2.37.2": false
        default: nil
        }
    }
}

/// One session for the suite's raw requests, which never stores or sends cookies.
private let cookielessSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    return URLSession(configuration: configuration)
}()

/// A request without the user's cookies or token, like the player's `AVURLAsset` for a session URL.
private func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await cookielessSession.data(for: request)
    return (data, try #require(response as? HTTPURLResponse))
}

/// A new device for every service, so sessions don't close each other.
private struct ContractDeviceIdentifier: DeviceIdentifying {
    let id = UUID().uuidString
    func deviceIdentifier() async -> String { id }
}

/// A book `scripts/test-server.sh` seeds in its "Streaming formats" library.
private func formatFixture(titled title: String) async throws -> String {
    let client = try await ContractAdmin.shared.session().client
    let libraries = try await client.send(LibraryEndpoints.libraries()).libraries
    let library = try #require(libraries.first { $0.name == "Streaming formats" }, "The streaming format library")
    let items = try await client.send(LibraryEndpoints.items(libraryID: library.id))
    return try #require(items.results.first { $0.book?.metadata.title == title }, "Seeded book \(title)").id
}

extension ContractSession {
    /// Starts a session with the app's service and request, resolves its stream as the player
    /// does, runs `body`, then closes the session, also when `body` throws. A closed session's
    /// URLs answer 404.
    fileprivate func streaming(
        _ itemID: String, forceTranscode: Bool = false,
        _ body: (PlaybackSession, ResolvedStream) async throws -> Void
    ) async throws {
        let service = APIPlaybackSessionService(
            serverConnectionID: UUID(), client: client, features: server.features,
            deviceIdentifiers: ContractDeviceIdentifier())
        let started = try await service.startSession(itemID: itemID, episodeID: nil, forceTranscode: forceTranscode)
        let stream: ResolvedStream
        do {
            stream = try await service.resolveStream(for: started)
            try await body(started, stream)
        } catch {
            try? await service.closeSession(id: started.id, report: nil)
            throw error
        }
        try await service.closeSession(id: started.id, report: nil)
        for url in stream.urls {
            #expect(try await fetch(URLRequest(url: url)).1.statusCode == 404)
        }
    }
}

/// Direct play: one session URL per file, in order, served with `mimeType`, whole and in byte
/// ranges, with no credentials (`SessionController.getTrack`).
private func expectDirectPlay(
    _ playback: PlaybackSession, _ stream: ResolvedStream, mimeType: String, startOffsets: [Double]
) async throws {
    #expect(playback.playMethod == .directPlay)
    #expect(stream.plan.kind == .directPlay)
    #expect(stream.plan.transport == .urlAsset)
    #expect(playback.audioTracks.compactMap(\.index) == Array(1...startOffsets.count))
    #expect(playback.audioTracks.count == startOffsets.count)
    for (track, offset) in zip(playback.audioTracks, startOffsets) {
        #expect(approximately(track.startOffset, offset), "track \(String(describing: track.index))")
    }
    #expect(stream.plan.tracks.map(\.mimeType) == Array(repeating: mimeType, count: startOffsets.count))
    #expect(stream.plan.tracks.allSatisfy { $0.authentication == .session })
    let files = try #require(playback.libraryItem?.book?.audioFiles)
    #expect(files.map(\.mimeType) == Array(repeating: mimeType, count: startOffsets.count))

    for (track, url) in zip(playback.audioTracks, stream.urls) {
        let index = try #require(track.index)
        #expect(url.path() == "/public/session/\(playback.id)/track/\(index)")
        #expect(url.query() == nil)
        let size = try #require(files.first { $0.index == index }?.metadata?.size)
        try #require(size > 2000)

        let (body, full) = try await fetch(URLRequest(url: url))
        #expect(full.statusCode == 200)
        #expect(full.value(forHTTPHeaderField: "Content-Type") == mimeType)
        #expect(full.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        #expect(body.count == size)

        var ranged = URLRequest(url: url)
        ranged.setValue("bytes=1000-1999", forHTTPHeaderField: "Range")
        let (part, partial) = try await fetch(ranged)
        #expect(partial.statusCode == 206)
        #expect(partial.value(forHTTPHeaderField: "Content-Range") == "bytes 1000-1999/\(size)")
        #expect(part == body.subdata(in: 1000..<2000))
    }
}

/// Whether `data` is whole MPEG-TS packets (188 bytes, each starting with the 0x47 sync byte).
private func isTransportStream(_ data: Data) -> Bool {
    !data.isEmpty && data.count.isMultiple(of: 188)
        && stride(from: data.startIndex, to: data.endIndex, by: 188).allSatisfy { data[$0] == 0x47 }
}

/// Polls for a segment `ffmpeg` writes after `/play` answers. Until then `HlsRouter` answers 404,
/// and a segment still being written may be cut short, so only whole packets count.
private func transcodedSegment(_ url: URL) async throws -> (Data, HTTPURLResponse) {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(30)
    while true {
        let (data, response) = try await fetch(URLRequest(url: url))
        if response.statusCode == 200, isTransportStream(data) { return (data, response) }
        if ![200, 404].contains(response.statusCode) || clock.now >= deadline { return (data, response) }
        try await Task.sleep(for: .milliseconds(250))
    }
}

/// Transcode: the session's HLS playlist and its first segment load with no credentials (ADR
/// 0007, decision 3); the playlist covers the whole book.
private func expectHLS(
    _ playback: PlaybackSession, _ stream: ResolvedStream, session: ContractSession, server: ContractServer
) async throws {
    #expect(playback.playMethod == .transcode)
    #expect(playback.audioTracks.map(\.mimeType) == ["application/vnd.apple.mpegurl"])
    #expect(stream.plan.kind == .hls)
    #expect(stream.plan.transport == .urlAsset)
    let track = try #require(stream.plan.tracks.first)
    #expect(stream.plan.tracks.count == 1)
    #expect(track.authentication == .session)
    #expect(stream.urls == [track.url])
    #expect(track.url.path() == "/hls/\(playback.id)/output.m3u8")
    #expect(track.url.query() == nil)

    let (body, response) = try await fetch(URLRequest(url: track.url))
    #expect(response.statusCode == 200)
    #expect(response.value(forHTTPHeaderField: "Content-Type") == "application/vnd.apple.mpegurl")
    let lines = String(decoding: body, as: UTF8.self).split(separator: "\n").map(String.init)
    #expect(lines.first == "#EXTM3U")
    #expect(lines.contains("#EXT-X-TARGETDURATION:6"))
    #expect(lines.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
    #expect(lines.last == "#EXT-X-ENDLIST")
    let durations = lines.compactMap { line -> Double? in
        guard line.hasPrefix("#EXTINF:") else { return nil }
        return Double(line.dropFirst("#EXTINF:".count).prefix { $0 != "," })
    }
    let uris = lines.filter { !$0.hasPrefix("#") }
    #expect(!uris.isEmpty)
    #expect(durations.count == uris.count)
    #expect(approximately(durations.reduce(0, +), playback.duration))

    let segments = uris.map { $0.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false) }
    #expect(segments.map { String($0[0]) } == uris.indices.map { "output-\($0).ts" })
    let queries = Set(segments.map { $0.count > 1 ? String($0[1]) : nil })
    switch server.hlsSegmentsCarryUserToken {
    case true?:
        // Every URI carries the same token, a working credential for the user that has no expiry.
        #expect(queries.count == 1)
        let query = try #require(queries.first ?? nil)
        #expect(query.hasPrefix("token="))
        try await expectLegacyToken(String(query.dropFirst("token=".count)), session: session)
    case false?:
        #expect(queries == [nil])
    case nil:
        break
    }

    // The segment needs neither the playlist's token nor an Authorization header.
    let (segment, segmentResponse) = try await transcodedSegment(
        track.url.deletingLastPathComponent().appending(path: "output-0.ts"))
    #expect(segmentResponse.statusCode == 200)
    #expect(segmentResponse.value(forHTTPHeaderField: "Content-Type") == "video/mp2t")
    #expect(isTransportStream(segment))
}

/// Checks that `token` signs `session`'s user in to the API and carries no `exp` claim.
private func expectLegacyToken(_ token: String, session: ContractSession) async throws {
    #expect(token != session.tokens.current?.accessToken)
    let base = session.configuration.baseURL
    var me = URLRequest(url: base.appending(path: "api/me"))
    me.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (body, response) = try await fetch(me)
    #expect(response.statusCode == 200)
    #expect(try JSONDecoder().decode(Me.self, from: body).id == session.user.id)

    let payload = try #require(token.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first)
    var base64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
    let claims = try #require(Data(base64Encoded: base64))
    let object = try #require(try JSONSerialization.jsonObject(with: claims) as? [String: Any])
    #expect(object["exp"] == nil)
}

private struct Me: Decodable {
    let id: String
}

@Suite(
    "Server contract: streaming formats", .requiresServer, .streamingFormatPass, .tags(.serverContract))
struct StreamingFormatContractTests {
    @Test("the production request offers MP3, MP4 and FLAC and never Ogg")
    func supportedTypes() {
        let types = SupportedAudioMIMETypes.current()
        #expect(types.contains("audio/mpeg"))
        #expect(types.contains("audio/mp4"))
        #expect(types.contains("audio/flac"))
        #expect(!types.contains("audio/ogg"))
    }

    @Test("a single-file M4B direct plays as audio/mp4 with byte ranges")
    func singleFileM4B() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            try await session.streaming(seed.singleFileID) { playback, stream in
                try await expectDirectPlay(playback, stream, mimeType: "audio/mp4", startOffsets: [0])
            }
        }
    }

    @Test("a multi-file MP3 book direct plays its files in order as audio/mpeg")
    func multiFileMP3() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            try await session.streaming(seed.taleID) { playback, stream in
                try await expectDirectPlay(playback, stream, mimeType: "audio/mpeg", startOffsets: [0, 30])
            }
        }
    }

    @Test("a FLAC book direct plays as audio/flac")
    func flac() async throws {
        let itemID = try await formatFixture(titled: "Flac Tale")
        try await ContractServer.require().withUser { session in
            try await session.streaming(itemID) { playback, stream in
                try await expectDirectPlay(playback, stream, mimeType: "audio/flac", startOffsets: [0])
            }
        }
    }

    @Test("an Opus book is audio/ogg, so it transcodes to HLS that needs no credentials")
    func opus() async throws {
        let itemID = try await formatFixture(titled: "Opus Tale")
        let server = try ContractServer.require()
        try await server.withUser { session in
            try await session.streaming(itemID) { playback, stream in
                #expect(playback.libraryItem?.book?.audioFiles?.map(\.mimeType) == ["audio/ogg"])
                try await expectHLS(playback, stream, session: session, server: server)
            }
        }
    }

    @Test("forceTranscode on the M4B serves the same HLS stream")
    func forcedTranscode() async throws {
        let seed = try await ContractSeed.shared.data()
        let server = try ContractServer.require()
        try await server.withUser { session in
            try await session.streaming(seed.singleFileID, forceTranscode: true) { playback, stream in
                #expect(playback.libraryItem?.book?.audioFiles?.map(\.mimeType) == ["audio/mp4"])
                try await expectHLS(playback, stream, session: session, server: server)
            }
        }
    }
}
