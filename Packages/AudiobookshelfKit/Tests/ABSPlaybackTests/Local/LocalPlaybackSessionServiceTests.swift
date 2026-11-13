import ABSCore
import ABSData
import Foundation
import Synchronization
import Testing

@testable import ABSAPI
@testable import ABSPlayback

/// Playing downloaded media from this device (ADR 0007, decision 7; #74).
@Suite(.timeLimit(.minutes(1)))
struct LocalPlaybackSessionServiceTests {
    static let connection = UUID()
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    let store: LocalProgressStore
    let items = LocalItems()
    let files = LocalFiles()

    init() throws {
        store = try LocalProgressStore(modelContainer: DataStack(location: .inMemory).container)
    }

    func service(now: Date = start) -> LocalPlaybackSessionService {
        let files = files
        return LocalPlaybackSessionService(
            serverConnectionID: Self.connection, items: items, progress: store,
            fileURL: { try LocalFiles.url(for: $0) }, fileExists: { files.exists($0) },
            deviceIdentifiers: LocalTestDevice(), now: { now })
    }

    @Test func buildsABookSessionFromItsDownloadedTracksAndChapters() async throws {
        items.add(.book())
        files.addAll(for: .book())

        let session = try await service().startSession(itemID: "book", episodeID: nil)

        #expect(UUID(uuidString: session.id) != nil)
        #expect(session.playMethod == .local && session.mediaPlayer == "AVPlayer")
        #expect(session.libraryItemId == "book" && session.episodeId == nil && session.userId == "user")
        #expect(session.deviceInfo?.deviceId == "device")
        #expect(session.displayTitle == "Dune" && session.displayAuthor == "Frank Herbert")
        #expect(session.audioTracks.map(\.startOffset) == [0, 100])
        #expect(session.audioTracks.map(\.contentUrl) == ["book/1.mp3", "book/2.m4b"])
        #expect(session.audioTracks.map(\.mimeType) == ["audio/mpeg", "audio/mp4"])
        #expect(session.duration == 250)
        #expect(
            session.chapters == [
                Chapter(id: 0, start: 0, end: 120, title: "One"), Chapter(id: 1, start: 120, end: 250, title: "Two"),
            ])
        #expect(session.startedAt == 1_800_000_000_000 && session.currentTime == 0)
        let timeline = PlaybackTimeline(session: session)
        #expect(timeline.duration == 250 && timeline.tracks.map(\.start) == [0, 100])
    }

    @Test func buildsAnEpisodeSessionFromItsOwnTrackAndChapters() async throws {
        items.add(.podcast())
        files.addAll(for: .podcast())

        let session = try await service().startSession(itemID: "show", episodeID: "ep2")

        #expect(session.episodeId == "ep2" && session.mediaType == .podcast)
        #expect(session.displayTitle == "Episode 2" && session.displayAuthor == "The Show")
        #expect(session.audioTracks.count == 1)
        #expect(session.audioTracks.first?.startOffset == 0 && session.audioTracks.first?.contentUrl == "show/ep2.mp3")
        #expect(session.duration == 60)
        #expect(session.chapters == [Chapter(id: 0, start: 0, end: 60, title: "Intro")])
    }

    /// The session starts at the saved local position, as the legacy app's does.
    @Test func startsAtTheSavedLocalPosition() async throws {
        items.add(.book())
        files.addAll(for: .book())
        try await store.recordEdit(
            ProgressEdit(audio: .init(currentTime: 130, duration: 250, progress: 0.52)), for: Self.key("book"))

        let session = try await service().startSession(itemID: "book", episodeID: nil)

        #expect(session.currentTime == 130 && session.startTime == 130)
    }

    @Test func resolvesTheSessionsFileURLsWithoutAToken() async throws {
        items.add(.book())
        files.addAll(for: .book())
        let service = service()
        let session = try await service.startSession(itemID: "book", episodeID: nil)

        let stream = try await service.resolveStream(for: session)

        #expect(stream.urls == [try LocalFiles.url(for: "book/1.mp3"), try LocalFiles.url(for: "book/2.m4b")])
        #expect(stream.plan.tracks.allSatisfy { $0.authentication == .localFile })
        #expect(stream.plan.tracks.map(\.mimeType) == ["audio/mpeg", "audio/mp4"])
        #expect(stream.plan.kind == .directPlay && stream.plan.transport == .urlAsset)
        #expect(stream.accessToken == nil && stream.transport == nil)
    }

    @Test func aFileDeletedAfterTheStartFailsToResolve() async throws {
        items.add(.book())
        files.addAll(for: .book())
        let service = service()
        let session = try await service.startSession(itemID: "book", episodeID: nil)
        files.remove("book/2.m4b")

        await #expect(throws: StreamResolutionError.resolution(.invalidContentURL)) {
            try await service.resolveStream(for: session)
        }
    }

    /// ADR 0007 §7: a download with a missing file is an error, not "not downloaded".
    @Test func aDownloadWithAMissingFileThrowsFilesMissing() async throws {
        items.add(.book())
        files.add("book/1.mp3")

        await #expect(throws: LocalPlaybackError.downloadFilesMissing(Self.key("book"))) {
            try await service().startSession(itemID: "book", episodeID: nil)
        }
    }

    /// No item, an ebook-only book download, or another episode of a downloaded show.
    @Test func mediaWithoutADownloadIsNotDownloaded() async throws {
        var ebookOnly = LocalLibraryItemDTO.book()
        ebookOnly.files.removeAll { $0.kind == .audio }
        items.add(ebookOnly)
        items.add(.podcast())
        files.addAll(for: .podcast())
        let service = service()

        for (item, episode) in [("missing", nil), ("book", nil), ("show", "ep3")] as [(String, String?)] {
            await #expect(throws: LocalPlaybackError.notDownloaded) {
                try await service.startSession(itemID: item, episodeID: episode)
            }
        }
    }

    /// Closing saves the session for upload, and a later close of the same id adds to its total.
    @Test func closeSavesAPendingSessionAndAccumulatesListeningTime() async throws {
        items.add(.book())
        files.addAll(for: .book())
        let service = service()
        let session = try await service.startSession(itemID: "book", episodeID: nil)
        #expect(try await store.session(id: session.id) == nil)

        try await service.closeSession(
            id: session.id, report: PlaybackSyncReport(currentTime: 40, timeListened: 30, duration: 250))
        try await service.closeSession(
            id: session.id, report: PlaybackSyncReport(currentTime: 70, timeListened: 25, duration: 250))

        let saved = try #require(try await store.session(id: session.id))
        #expect(UUID(uuidString: saved.id) != nil)
        #expect(saved.key == Self.key("book") && saved.userId == "user" && saved.mediaType == .book)
        #expect(saved.playMethod == PlayMethod.local.rawValue)
        #expect(saved.timeListening == 55 && saved.currentTime == 70 && saved.startTime == 0)
        #expect(saved.displayTitle == "Dune" && saved.duration == 250 && !saved.isActive)
        #expect(saved.startedAt == Self.start)
        #expect(await service.sessionStatus(id: session.id) == .alive)
    }

    @Test func eachStartHasItsOwnSession() async throws {
        items.add(.book())
        files.addAll(for: .book())
        let service = service()

        let first = try await service.startSession(itemID: "book", episodeID: nil)
        let second = try await service.startSession(itemID: "book", episodeID: nil)

        #expect(first.id != second.id)
        #expect(await service.sessionStatus(id: first.id) == .alive)
        #expect(await service.sessionStatus(id: "other") == .unknown)
    }

    /// The coordinator takes this as the server's progress, so it is the server baseline the row
    /// last saw, never the unsent local position.
    @Test func mediaProgressIsTheServerBaselineNotTheLocalPosition() async throws {
        let seen = ProgressBaseline(
            currentTime: 100, progress: 0.4, duration: 250, isFinished: false, lastUpdate: Self.start)
        try await store.recordEdit(
            ProgressEdit(audio: .init(currentTime: 130, duration: 250, progress: 0.52)), for: Self.key("book"),
            serverProgress: seen, now: Self.start.addingTimeInterval(60))

        let progress = try #require(try await service().mediaProgress(itemID: "book", episodeID: nil))

        #expect(progress.currentTime == 100 && progress.duration == 250 && !progress.isFinished)
        #expect(progress.lastUpdate == 1_800_000_000_000 && progress.libraryItemId == "book")
        #expect(try await service().mediaProgress(itemID: "other", episodeID: nil) == nil)
    }

    static func key(_ item: String, episode: String? = nil) -> MediaKey {
        MediaKey(serverConnectionID: connection, libraryItemId: item, episodeId: episode)
    }
}

/// Downloaded items by library item id.
final class LocalItems: LocalItemReading {
    private let items = Mutex<[String: LocalLibraryItemDTO]>([:])

    func add(_ item: LocalLibraryItemDTO) { items.withLock { $0[item.libraryItemId] = item } }

    func item(serverConnectionID: UUID, libraryItemId: String) async throws -> LocalLibraryItemDTO? {
        items.withLock { $0[libraryItemId] }.flatMap { $0.serverConnectionID == serverConnectionID ? $0 : nil }
    }
}

/// The files on "disk", by relative path.
final class LocalFiles: Sendable {
    static let root = URL(filePath: "/downloads", directoryHint: .isDirectory)
    private let paths = Mutex<Set<String>>([])

    static func url(for path: String) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw URLError(.badURL)
        }
        return root.appending(path: path, directoryHint: .notDirectory)
    }

    func add(_ path: String) { _ = paths.withLock { $0.insert(path) } }
    func remove(_ path: String) { _ = paths.withLock { $0.remove(path) } }

    func addAll(for item: LocalLibraryItemDTO) {
        for file in item.files { add(file.relativePath) }
    }

    func exists(_ url: URL) -> Bool {
        paths.withLock { $0.contains { (try? LocalFiles.url(for: $0)) == url } }
    }
}

struct LocalTestDevice: DeviceIdentifying {
    func deviceIdentifier() async -> String { "device" }
}

extension LocalLibraryItemDTO {
    /// Two tracks (0–100, 100–250) with two chapters.
    static func book(connection: UUID = LocalPlaybackSessionServiceTests.connection) -> Self {
        let snapshot = LocalMediaSnapshot(
            metadata: .init(title: "Dune", authors: ["Frank Herbert"]),
            chapters: [
                .init(id: 0, start: 0, end: 120, title: "One"), .init(id: 1, start: 120, end: 250, title: "Two"),
            ],
            audioTracks: [
                .init(index: 1, title: "1", duration: 100, startOffset: 0, mimeType: "audio/mpeg"),
                .init(index: 2, title: "2", duration: 150, startOffset: 100, mimeType: "audio/mp4"),
            ])
        return LocalLibraryItemDTO(
            id: UUID(), serverConnectionID: connection, serverAddress: "https://abs.example", serverUserId: "user",
            libraryItemId: "book", mediaType: .book, title: "Dune", authorName: "Frank Herbert",
            relativeDirectory: "book", addedAt: LocalPlaybackSessionServiceTests.start,
            updatedAt: LocalPlaybackSessionServiceTests.start, media: snapshot,
            files: [
                LocalFileDTO(
                    kind: .audio, relativePath: "book/1.mp3", filename: "1.mp3", mimeType: "audio/mpeg", size: 1,
                    trackIndex: 1),
                LocalFileDTO(
                    kind: .audio, relativePath: "book/2.m4b", filename: "2.m4b", mimeType: "audio/mp4", size: 1,
                    trackIndex: 2),
                LocalFileDTO(
                    kind: .ebook, relativePath: "book/dune.epub", filename: "dune.epub",
                    mimeType: "application/epub+zip", size: 1),
            ])
    }

    /// A show with two downloaded episodes; episode 2's track sits at 300 s in the show's snapshot.
    static func podcast(connection: UUID = LocalPlaybackSessionServiceTests.connection) -> Self {
        let snapshot = LocalMediaSnapshot(
            metadata: .init(title: "The Show"),
            episodes: [
                .init(
                    id: "ep1", title: "Episode 1",
                    track: .init(index: 1, title: "ep1", duration: 300, startOffset: 0, mimeType: "audio/mpeg")),
                .init(
                    id: "ep2", title: "Episode 2", chapters: [.init(id: 0, start: 0, end: 60, title: "Intro")],
                    track: .init(index: 1, title: "ep2", duration: 60, startOffset: 300, mimeType: "audio/mpeg")),
            ])
        return LocalLibraryItemDTO(
            id: UUID(), serverConnectionID: connection, serverAddress: "https://abs.example", serverUserId: "user",
            libraryItemId: "show", mediaType: .podcast, title: "The Show", relativeDirectory: "show",
            addedAt: LocalPlaybackSessionServiceTests.start, updatedAt: LocalPlaybackSessionServiceTests.start,
            media: snapshot,
            files: [
                LocalFileDTO(
                    kind: .audio, relativePath: "show/ep1.mp3", filename: "ep1.mp3", mimeType: "audio/mpeg", size: 1,
                    trackIndex: 1, episodeId: "ep1"),
                LocalFileDTO(
                    kind: .audio, relativePath: "show/ep2.mp3", filename: "ep2.mp3", mimeType: "audio/mpeg", size: 1,
                    trackIndex: 1, episodeId: "ep2"),
            ])
    }
}
