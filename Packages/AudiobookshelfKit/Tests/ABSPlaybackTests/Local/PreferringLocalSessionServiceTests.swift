import ABSCore
import ABSData
import Foundation
import Synchronization
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// Choosing between a downloaded copy and streaming (ADR 0007, decision 7; #74).
@Suite(.timeLimit(.minutes(1)))
struct PreferringLocalSessionServiceTests {
    let store: LocalProgressStore
    let items = LocalItems()
    let files = LocalFiles()
    let remote = RemoteSessions()

    init() throws {
        store = try LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
    }

    func service() -> PreferringLocalSessionService {
        let files = files
        let local = LocalPlaybackSessionService(
            serverConnectionID: LocalPlaybackSessionServiceTests.connection, items: items, progress: store,
            fileURL: { try LocalFiles.url(for: $0) }, fileExists: { files.exists($0) })
        return PreferringLocalSessionService(local: local, remote: remote)
    }

    @Test func playsADownloadedBookFromItsFiles() async throws {
        items.add(.book())
        files.addAll(for: .book())
        let service = service()

        let session = try await service.startSession(itemID: "book", episodeID: nil)
        let stream = try await service.resolveStream(for: session)
        try await service.closeSession(
            id: session.id, report: PlaybackSyncReport(currentTime: 20, timeListened: 20, duration: 250))

        #expect(session.playMethod == .local)
        #expect(stream.plan.tracks.allSatisfy { $0.authentication == .localFile })
        #expect(try await store.session(id: session.id)?.timeListening == 20)
        #expect(await service.sessionStatus(id: session.id) == .alive)
        #expect(remote.calls.isEmpty)
    }

    @Test func playsADownloadedEpisodeOnlyForThatEpisode() async throws {
        items.add(.podcast())
        files.addAll(for: .podcast())
        let service = service()

        let downloaded = try await service.startSession(itemID: "show", episodeID: "ep1")
        let streamed = try await service.startSession(itemID: "show", episodeID: "ep3")

        #expect(downloaded.playMethod == .local)
        #expect(streamed.playMethod == .directPlay && remote.calls == ["start show ep3"])
    }

    @Test func streamsMediaThatIsNotDownloaded() async throws {
        let service = service()

        let session = try await service.startSession(itemID: "book", episodeID: nil)
        _ = try await service.resolveStream(for: session)
        try await service.closeSession(id: session.id, report: nil)

        #expect(session.playMethod == .directPlay)
        #expect(remote.calls == ["start book", "resolve remote-book", "close remote-book"])
    }

    /// A download whose file is gone streams instead.
    @Test func streamsWhenADownloadedFileIsMissing() async throws {
        items.add(.book())
        files.addAll(for: .book())
        files.remove("book/1.mp3")
        let service = service()

        let session = try await service.startSession(itemID: "book", episodeID: nil)

        #expect(session.playMethod == .directPlay && remote.calls == ["start book"])
        #expect(try await store.pendingSessions(for: LocalPlaybackSessionServiceTests.connection).isEmpty)
    }

    /// The server's progress still wins when it answers; offline, downloaded media gets the
    /// baseline the device last saw.
    @Test func progressComesFromTheServerAndFallsBackToTheLocalBaselineOffline() async throws {
        items.add(.book())
        files.addAll(for: .book())
        let seen = ProgressBaseline(
            currentTime: 100, progress: 0.4, duration: 250, isFinished: false,
            lastUpdate: LocalPlaybackSessionServiceTests.start)
        try await store.recordEdit(
            ProgressEdit(), for: LocalPlaybackSessionServiceTests.key("book"), serverProgress: seen)
        let service = service()

        #expect(try await service.mediaProgress(itemID: "book", episodeID: nil)?.currentTime == 42)
        remote.failProgress()
        #expect(try await service.mediaProgress(itemID: "book", episodeID: nil)?.currentTime == 100)
        await #expect(throws: APIError.self) {
            try await service.mediaProgress(itemID: "other", episodeID: nil)
        }
    }
}

/// A streaming service that records its calls.
final class RemoteSessions: PlaybackSessionService {
    let serverConnectionID = LocalPlaybackSessionServiceTests.connection
    private let state = Mutex<(calls: [String], progressFails: Bool)>(([], false))

    var calls: [String] { state.withLock { $0.calls } }
    func failProgress() { state.withLock { $0.progressFails = true } }

    private func record(_ call: String) { state.withLock { $0.calls.append(call) } }

    func startSession(itemID: String, episodeID: String?) async throws -> PlaybackSession {
        record(["start", itemID, episodeID].compactMap(\.self).joined(separator: " "))
        return PlaybackSession(
            id: "remote-\(itemID)", libraryItemId: itemID, episodeId: episodeID, mediaType: .book,
            audioTracks: [AudioTrack(index: 1, startOffset: 0, duration: 10)])
    }

    func mediaProgress(itemID: String, episodeID: String?) async throws -> MediaProgress? {
        if state.withLock({ $0.progressFails }) { throw APIError.network(.notConnectedToInternet) }
        return MediaProgress(id: "p", libraryItemId: itemID, currentTime: 42, lastUpdate: 1)
    }

    func resolveStream(for session: PlaybackSession) async throws -> ResolvedStream {
        record("resolve \(session.id)")
        return ResolvedStream(plan: .localFiles([]), urls: [])
    }

    func closeSession(id: String, report: PlaybackSyncReport?) async throws { record("close \(id)") }

    func refreshStreamAccess(replacing rejected: String?) async throws { record("refresh") }
}
