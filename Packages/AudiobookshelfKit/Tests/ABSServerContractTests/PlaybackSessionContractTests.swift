import ABSCore
import Foundation
import Testing

@testable import ABSAPI

/// A request without the user's cookies or token, like the player's `AVURLAsset` for a session URL.
private func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
    return (data, try #require(response as? HTTPURLResponse))
}

extension ContractSession {
    fileprivate func open(_ playback: PlaybackSession) async throws -> PlaybackSession {
        try await client.send(SessionEndpoints.openSession(id: playback.id))
    }

    /// Uploads sessions like the app's offline sync: `POST /api/session/local-all`.
    fileprivate func upload(_ sessions: [PlaybackSession], device: DeviceInfo) async throws -> [LocalSessionSyncResult]
    {
        let payloads = try sessions.map { try LocalPlaybackSessionPayload(session: $0, deviceInfo: device) }
        let batch = try LocalPlaybackSessionBatch(sessions: payloads, deviceInfo: device)
        return try await client.send(SessionEndpoints.syncLocalAll(batch)).results
    }
}

/// A session played offline: `startedAt` and `updatedAt` are when it was played.
private func localSession(
    itemID: String, id: String = UUID().uuidString, current: Double, listened: Double, updatedAt: Date = .now
) -> PlaybackSession {
    PlaybackSession(
        id: id, libraryItemId: itemID, mediaType: .book, displayTitle: "The Synthetic Tale",
        displayAuthor: "Ada Fixture", duration: 50, playMethod: .local, mediaPlayer: PlaybackStartRequest.avPlayer,
        timeListening: listened, startTime: 0, currentTime: current,
        startedAt: milliseconds(updatedAt.addingTimeInterval(-listened)), updatedAt: milliseconds(updatedAt))
}

@Suite("Server contract: playback sessions", .requiresServer, .tags(.serverContract))
struct PlaybackSessionContractTests {
    @Test("a session starts with the item's tracks and chapters, then syncs and closes")
    func startSyncClose() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            let empty = try await session.client.send(SessionEndpoints.listeningSessions(itemID: seed.taleID))
            #expect(empty.sessions.isEmpty)
            let device = contractDevice()
            let started = try await session.play(seed.taleID, device: device)
            #expect(started.playMethod == .directPlay)
            #expect(started.mediaType == .book)
            #expect(started.libraryItemId == seed.taleID)
            #expect(started.libraryId == seed.bookLibraryID)
            #expect(started.userId == session.user.id)
            #expect(started.episodeId == nil)
            #expect(started.displayTitle == "The Synthetic Tale")
            #expect(started.displayAuthor == "Ada Fixture")
            #expect(started.deviceInfo?.deviceId == device.deviceId)
            #expect(started.serverVersion == session.server.status.serverVersion)
            #expect(started.startTime == 0)
            #expect(started.timeListening == 0)
            #expect(approximately(started.duration, 50))
            #expect(started.chapters.map(\.title) == ["Part One", "Part Two"])
            #expect(started.audioTracks.map(\.index) == [1, 2])
            #expect(started.audioTracks.map(\.mimeType) == ["audio/mpeg", "audio/mpeg"])
            #expect(approximately(started.audioTracks.last?.startOffset, 30))
            #expect(started.libraryItem?.id == seed.taleID)

            // `timeListened` is a delta that the server adds up; `currentTime` is the position.
            try await session.sync(started, to: 10, listened: 2)
            try await session.sync(started, to: 11.5, listened: 1.5)
            let open = try await session.open(started)
            #expect(open.currentTime == 11.5)
            #expect(approximately(open.timeListening, 3.5, tolerance: 0.001))
            // A sync is also what creates the user's progress.
            let synced = try #require(try await session.client.mediaProgress(itemID: seed.taleID))
            #expect(synced.currentTime == 11.5)
            #expect(approximately(synced.progress, 11.5 / started.duration, tolerance: 0.001))
            #expect(!synced.isFinished)

            let closing = try session.report(20, listened: 4, duration: started.duration)
            _ = try await session.client.send(SessionEndpoints.close(sessionID: started.id, report: closing))
            let closed = try #require(try await session.client.mediaProgress(itemID: seed.taleID))
            #expect(closed.currentTime == 20)
            let page = try await session.client.send(SessionEndpoints.listeningSessions(itemID: seed.taleID))
            let stored = try #require(page.sessions.first { $0.id == started.id })
            #expect(stored.currentTime == 20)
            #expect(approximately(stored.timeListening, 7.5, tolerance: 0.001))

            // A closed session is gone: the app must treat 404 as "upload this as a local session".
            await expectNotFound { try await session.open(started) }
            await expectNotFound { try await session.sync(started, to: 21, listened: 1) }
            await expectNotFound { try await session.client.send(SessionEndpoints.close(sessionID: started.id)) }
        }
    }

    @Test("starting again resumes where the last session was synced")
    func resume() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            let device = contractDevice()
            let first = try await session.play(seed.taleID, device: device)
            try await session.sync(first, to: 25, listened: 5)
            _ = try await session.client.send(SessionEndpoints.close(sessionID: first.id))

            let second = try await session.play(seed.taleID, device: device)
            #expect(second.id != first.id)
            #expect(second.startTime == 25)
            #expect(second.currentTime == 25)
            #expect(second.timeListening == 0)
        }
    }

    @Test("a new session closes this user's other sessions on the same device only")
    func sameDeviceTakeover() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            let phone = contractDevice()
            let first = try await session.play(seed.taleID, device: phone)
            try await session.sync(first, to: 10, listened: 3)
            let watch = try await session.play(seed.taleID, device: contractDevice())
            _ = try await session.open(first)

            // Even for another book: the server closes by user and device.
            let second = try await session.play(seed.singleFileID, device: phone)
            await expectNotFound { try await session.open(first) }
            await expectNotFound { try await session.sync(first, to: 11, listened: 1) }
            #expect(try await session.open(second).id == second.id)
            #expect(try await session.open(watch).id == watch.id)
            // What was synced before the takeover is kept.
            #expect(try await session.client.mediaProgress(itemID: seed.taleID)?.currentTime == 10)

            let third = try await session.play(seed.singleFileID, device: phone)
            await expectNotFound { try await session.open(second) }
            #expect(try await session.open(third).id == third.id)
        }
    }

    @Test("a podcast episode session carries the episode and its own progress")
    func episode() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            let started = try await session.play(seed.podcastID, episodeID: seed.episodeID)
            #expect(started.mediaType == .podcast)
            #expect(started.libraryItemId == seed.podcastID)
            #expect(started.episodeId == seed.episodeID)
            #expect(started.bookId == nil)
            #expect(started.displayTitle == "Episode One")
            #expect(approximately(started.duration, 20))
            #expect(started.audioTracks.map(\.index) == [1])

            try await session.sync(started, to: 8, listened: 3)
            let progress = try #require(
                try await session.client.mediaProgress(itemID: seed.podcastID, episodeID: seed.episodeID))
            #expect(progress.currentTime == 8)
            #expect(progress.episodeId == seed.episodeID)
            #expect(progress.mediaItemType == .podcastEpisode)
            #expect(progress.mediaItemId == seed.episodeID)
        }
    }

    @Test("track URLs stream by session id alone, support ranges and stop with the session")
    func trackURLs() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            let started = try await session.play(seed.taleID)
            let plan = try TrackURLResolver.resolve(
                session: started, features: session.server.features, configuration: session.configuration)
            #expect(plan.kind == .directPlay)
            #expect(plan.tracks.map(\.mimeType) == ["audio/mpeg", "audio/mpeg"])
            #expect(plan.tracks.allSatisfy { $0.authentication == .session })
            #expect(approximately(plan.tracks.last?.startOffset, 30))
            let track = try #require(plan.tracks.first)
            let size = try #require(started.libraryItem?.book?.audioFiles?.first?.metadata?.size)

            let (body, full) = try await fetch(URLRequest(url: track.url))
            #expect(full.statusCode == 200)
            #expect(full.value(forHTTPHeaderField: "Content-Type") == "audio/mpeg")
            #expect(full.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
            #expect(body.count == size)

            var ranged = URLRequest(url: track.url)
            ranged.setValue("bytes=0-99", forHTTPHeaderField: "Range")
            let (head, partial) = try await fetch(ranged)
            #expect(partial.statusCode == 206)
            #expect(partial.value(forHTTPHeaderField: "Content-Range") == "bytes 0-99/\(size)")
            #expect(head == body.prefix(100))

            let base = session.configuration.baseURL
            let missing = try APIClient.url(base: base, path: "/public/session/\(started.id)/track/9", query: [])
            #expect(try await fetch(URLRequest(url: missing)).1.statusCode == 404)

            _ = try await session.client.send(SessionEndpoints.close(sessionID: started.id))
            #expect(try await fetch(URLRequest(url: track.url)).1.statusCode == 404)
        }
    }

    @Test("a library file downloads with the bearer token and not without it")
    func download() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            let item = try await session.client.send(ItemEndpoints.item(id: seed.taleID))
            let file = try #require(item.book?.audioFiles?.first)
            let size = try #require(file.metadata?.size)
            let path = DownloadRequests.filePath(itemID: seed.taleID, ino: file.ino)
            let token = try #require(session.tokens.current).accessToken
            let request = try DownloadRequests.request(
                path: path, configuration: session.configuration, accessToken: token)

            let (body, response) = try await fetch(request)
            #expect(response.statusCode == 200)
            #expect(body.count == size)
            #expect(body.prefix(3) == Data("ID3".utf8))

            var ranged = request
            ranged.setValue("bytes=10-19", forHTTPHeaderField: "Range")
            let (part, partial) = try await fetch(ranged)
            #expect(partial.statusCode == 206)
            #expect(part == body[10...19])

            let rejected = try DownloadRequests.request(
                path: path, configuration: session.configuration, accessToken: "not-a-token")
            #expect(try await fetch(rejected).1.statusCode == 401)
        }
    }

    @Test("locally played sessions upload once, resends overwrite and stale ones keep newer progress")
    func localUpload() async throws {
        let seed = try await ContractSeed.shared.data()
        try await ContractServer.require().withUser { session in
            let device = contractDevice()
            let id = UUID().uuidString
            let first = try await session.upload(
                [localSession(itemID: seed.taleID, id: id, current: 12, listened: 6)], device: device)
            #expect(first.map(\.id) == [id])
            #expect(first.map(\.success) == [true])
            #expect(first.map(\.progressSynced) == [true])
            let created = try #require(try await session.client.mediaProgress(itemID: seed.taleID))
            #expect(created.currentTime == 12)
            #expect(approximately(created.progress, 12.0 / 50, tolerance: 0.001))
            let listened = try await session.client.send(StatsEndpoints.listeningStats()).stats.totalTime
            #expect(approximately(listened, 6, tolerance: 0.001))

            // The same id again replaces the stored session: listening time is not added twice.
            let resend = try await session.upload(
                [localSession(itemID: seed.taleID, id: id, current: 14, listened: 8)], device: device)
            #expect(resend.map(\.progressSynced) == [true])
            #expect(try await session.client.mediaProgress(itemID: seed.taleID)?.currentTime == 14)
            let total = try await session.client.send(StatsEndpoints.listeningStats()).stats.totalTime
            #expect(approximately(total, 8, tolerance: 0.001))

            // A session last updated before the server's progress is stored but doesn't move it.
            let old = localSession(
                itemID: seed.taleID, current: 3, listened: 2, updatedAt: .now.addingTimeInterval(-600))
            let stale = try await session.upload([old], device: device)
            #expect(stale.map(\.success) == [true])
            #expect(stale.map(\.progressSynced) == [false])
            #expect(try await session.client.mediaProgress(itemID: seed.taleID)?.currentTime == 14)

            // An item the server doesn't have fails for that session only.
            let lost = localSession(itemID: "li_missing", current: 1, listened: 1)
            let mixed = try await session.upload(
                [lost, localSession(itemID: seed.taleID, current: 30, listened: 1)], device: device)
            #expect(mixed.map(\.success) == [false, true])
            #expect(mixed.first?.error?.contains("not found") == true)
            #expect(try await session.client.mediaProgress(itemID: seed.taleID)?.currentTime == 30)

            // The single-session route takes the same payload.
            let single = try LocalPlaybackSessionPayload(
                session: localSession(itemID: seed.taleID, current: 31, listened: 1), deviceInfo: device)
            _ = try await session.client.send(SessionEndpoints.syncLocal(single))
            #expect(try await session.client.mediaProgress(itemID: seed.taleID)?.currentTime == 31)
        }
    }
}
