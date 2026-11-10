import ABSCore
import Foundation
import Testing

@testable import ABSAPI

private func makeClient(_ server: StubServer) throws -> APIClient {
    APIClient(
        configuration: try APIClientConfiguration(baseURL: server.baseURL),
        tokenProvider: InMemoryTokenProvider(),
        sessionConfiguration: server.sessionConfiguration()
    )
}

private func jsonBody(_ request: URLRequest?) throws -> [String: Any] {
    let body = try #require(request?.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
}

private let deviceInfo: DeviceInfo = {
    var info = DeviceInfo(
        deviceId: "DEVICE-UUID", manufacturer: "Apple", model: "Mac15,3", clientName: "Audiobookshelf Apple",
        clientVersion: "1.0")
    info.sdkVersion = "27.2.0"
    return info
}()

@Suite struct SessionEndpointsTests {
    @Test func startBookSessionSendsADR0007Body() async throws {
        let server = StubServer { _ in .json(multiTrackSessionJSON) }
        let request = PlaybackStartRequest(
            deviceInfo: deviceInfo, supportedMimeTypes: ["audio/mpeg", "audio/mp4", "audio/flac"])

        let session = try await makeClient(server).send(SessionEndpoints.start(itemID: "li-1", request: request))

        #expect(session.audioTracks.count == 3)
        let sent = try #require(server.requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path() == "/abs/api/items/li-1/play")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        let json = try jsonBody(sent)
        #expect(
            Set(json.keys) == ["deviceInfo", "supportedMimeTypes", "mediaPlayer", "forceDirectPlay", "forceTranscode"])
        #expect(json["supportedMimeTypes"] as? [String] == ["audio/mpeg", "audio/mp4", "audio/flac"])
        #expect(json["mediaPlayer"] as? String == "AVPlayer")
        #expect(json["forceDirectPlay"] as? Bool == false)
        #expect(json["forceTranscode"] as? Bool == false)
        #expect(
            json["deviceInfo"] as? [String: String] == [
                "deviceId": "DEVICE-UUID", "clientName": "Audiobookshelf Apple", "clientVersion": "1.0",
                "manufacturer": "Apple", "model": "Mac15,3", "sdkVersion": "27.2.0",
            ])
    }

    @Test func startEpisodeSessionWithForcedTranscode() async throws {
        let server = StubServer { _ in .json(multiTrackSessionJSON) }
        let request = PlaybackStartRequest(deviceInfo: deviceInfo, supportedMimeTypes: [], forceTranscode: true)

        _ = try await makeClient(server).send(
            SessionEndpoints.start(itemID: "li/1", episodeID: "ep 1", request: request))

        let sent = try #require(server.requests.first)
        #expect(sent.url?.absoluteString == "https://\(server.host)/abs/api/items/li%2F1/play/ep%201")
        let json = try jsonBody(sent)
        #expect(json["forceTranscode"] as? Bool == true)
        #expect(json["forceDirectPlay"] as? Bool == false)
    }

    @Test func syncSendsCurrentTimeTimeListenedAndDuration() async throws {
        let server = StubServer { _ in .text("OK", status: 200) }
        _ = try await makeClient(server).send(
            SessionEndpoints.sync(
                sessionID: "s/1", report: PlaybackSyncReport(currentTime: 120.5, timeListened: 15, duration: 5400)))

        let sent = try #require(server.requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString == "https://\(server.host)/abs/api/session/s%2F1/sync")
        let json = try jsonBody(sent)
        #expect(Set(json.keys) == ["currentTime", "timeListened", "duration"])
        #expect(json["currentTime"] as? Double == 120.5)
        #expect(json["timeListened"] as? Double == 15)
        #expect(json["duration"] as? Double == 5400)
    }

    @Test func closeWithAndWithoutFinalReport() async throws {
        let server = StubServer { _ in .text("OK", status: 200) }
        let client = try makeClient(server)
        _ = try await client.send(SessionEndpoints.close(sessionID: "s1"))
        _ = try await client.send(
            SessionEndpoints.close(
                sessionID: "s1", report: PlaybackSyncReport(currentTime: 10, timeListened: 2.5, duration: 100)))

        let requests = server.requests(path: "/abs/api/session/s1/close")
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.httpMethod == "POST" })
        #expect(requests[0].httpBody == nil)
        #expect(try jsonBody(requests[1])["timeListened"] as? Double == 2.5)
    }

    @Test func openSessionDecodesTheLiveSession() async throws {
        let server = StubServer { _ in .json(multiTrackSessionJSON) }
        let session = try await makeClient(server).send(SessionEndpoints.openSession(id: "3f2b"))
        let sent = try #require(server.requests.first)
        #expect(sent.httpMethod == "GET")
        #expect(sent.url?.path() == "/abs/api/session/3f2b")
        #expect(session.id == "3f2b8e4c-9d1a-4c6e-8f00-1a2b3c4d5e6f")
    }

    @Test func openSessionNotFoundIsAnHTTPError() async throws {
        let server = StubServer { _ in .text("Not Found", status: 404) }
        await #expect(throws: APIError.notFound) {
            try await makeClient(server).send(SessionEndpoints.openSession(id: "gone"))
        }
    }

    @Test func syncLocalSendsTheSessionWithDeviceInfo() async throws {
        let server = StubServer { _ in .text("OK", status: 200) }
        let session = PlaybackSession(
            id: "8c1d6a52-6b6f-4f0e-9a43-3d0c1e2f4a5b", libraryItemId: "li-1", episodeId: "ep-1",
            mediaType: .podcast, displayTitle: "Episode", displayAuthor: "Host", duration: 1800,
            playMethod: .local, mediaPlayer: "AVPlayer", deviceInfo: deviceInfo, timeListening: 42.5,
            startTime: 10, currentTime: 52.5, startedAt: 1_762_732_800_000, updatedAt: 1_762_732_842_500)

        _ = try await makeClient(server).send(
            SessionEndpoints.syncLocal(LocalPlaybackSessionPayload(session: session, includeDeviceInfo: true)))

        let sent = try #require(server.requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path() == "/abs/api/session/local")
        let json = try jsonBody(sent)
        #expect(json["id"] as? String == "8c1d6a52-6b6f-4f0e-9a43-3d0c1e2f4a5b")
        #expect(json["libraryItemId"] as? String == "li-1")
        #expect(json["episodeId"] as? String == "ep-1")
        #expect(json["mediaType"] as? String == "podcast")
        #expect(json["playMethod"] as? Int == 3)
        #expect(json["mediaPlayer"] as? String == "AVPlayer")
        #expect(json["duration"] as? Double == 1800)
        #expect(json["startTime"] as? Double == 10)
        #expect(json["currentTime"] as? Double == 52.5)
        #expect(json["timeListening"] as? Double == 42.5)
        #expect(json["startedAt"] as? Int == 1_762_732_800_000)
        #expect(json["updatedAt"] as? Int == 1_762_732_842_500)
        #expect(json["displayTitle"] as? String == "Episode")
        #expect((json["deviceInfo"] as? [String: String])?["deviceId"] == "DEVICE-UUID")
    }

    @Test func syncLocalAllBatchesSessionsWithOneDeviceInfo() async throws {
        let server = StubServer { _ in
            .json(
                #"{"results":[{"id":"a","success":true,"progressSynced":true},"#
                    + #"{"id":"b","success":false,"error":"Media item not found"}]}"#)
        }
        let sessions = ["a", "b"].map {
            LocalPlaybackSessionPayload(
                session: PlaybackSession(
                    id: $0, libraryItemId: "li-\($0)", mediaType: .book, playMethod: .local, deviceInfo: deviceInfo),
                includeDeviceInfo: false)
        }

        let response = try await makeClient(server).send(
            SessionEndpoints.syncLocalAll(LocalPlaybackSessionBatch(sessions: sessions, deviceInfo: deviceInfo)))

        #expect(response.results.map(\.id) == ["a", "b"])
        #expect(response.results[0].progressSynced == true)
        #expect(response.results[1].success == false)
        #expect(response.results[1].error == "Media item not found")
        let sent = try #require(server.requests.first)
        #expect(sent.url?.path() == "/abs/api/session/local-all")
        let json = try jsonBody(sent)
        #expect((json["deviceInfo"] as? [String: String])?["deviceId"] == "DEVICE-UUID")
        let sentSessions = try #require(json["sessions"] as? [[String: Any]])
        #expect(sentSessions.map { $0["id"] as? String } == ["a", "b"])
        #expect(sentSessions.allSatisfy { $0["deviceInfo"] == nil && $0["episodeId"] == nil })
        #expect(sentSessions.allSatisfy { $0["mediaPlayer"] as? String == "AVPlayer" })
    }

    @Test func decodesMultiTrackSession() throws {
        let session = try decodeMultiTrackSession()
        #expect(session.playMethod == .directPlay)
        #expect(session.mediaType == .book)
        #expect(session.duration == 5400.75)
        #expect(session.currentTime == 1234.5)
        #expect(session.timeListening == 0)
        #expect(session.chapters.count == 2)
        #expect(session.deviceInfo?.deviceId == "DEVICE-UUID")
        #expect(session.deviceInfo?.sdkVersion == "27.0.0")
        #expect(session.audioTracks.map(\.index) == [1, 2, 3])
        #expect(session.audioTracks.map(\.startOffset) == [0, 1800.5, 4000.25])
        #expect(session.audioTracks.map(\.mimeType) == ["audio/mpeg", "audio/mpeg", "audio/mpeg"])
        #expect(session.audioTracks.last?.endOffset == 5400.75)
        #expect(session.libraryItem == nil)
    }
}
