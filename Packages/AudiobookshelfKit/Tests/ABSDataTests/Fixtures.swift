import ABSCore
import Foundation
import SwiftData

@testable import ABSData

/// Small builders for test rows; every argument that matters to a test is explicit.
enum Fixtures {
    static let connectionID = UUID(uuidString: "6F1E2A4B-1C2D-4E5F-8A9B-0C1D2E3F4A5B")!
    static let date = Date(timeIntervalSince1970: 1_800_000_000)

    static func mediaKey(_ libraryItemId: String, episodeId: String? = nil) -> String {
        MediaKey(serverConnectionID: connectionID, libraryItemId: libraryItemId, episodeId: episodeId).rawValue
    }

    static let bookSnapshot = LocalMediaSnapshot(
        metadata: .init(
            title: "The Book",
            subtitle: "A Subtitle",
            authors: ["Author One", "Author Two"],
            narrators: ["Narrator"],
            series: [.init(name: "Series", sequence: "1.5")],
            description: "Description",
            publishedYear: "2001",
            explicit: true,
            abridged: false
        ),
        chapters: [
            .init(id: 0, start: 0, end: 600.5, title: "Chapter 1"),
            .init(id: 1, start: 600.5, end: 1200, title: "Chapter 2"),
        ],
        audioTracks: [
            .init(index: 1, title: "Part 1", duration: 900, startOffset: 0, mimeType: "audio/mpeg", ino: "11"),
            .init(index: 2, title: "Part 2", duration: 300, startOffset: 900, mimeType: "audio/mpeg"),
        ],
        ebookFile: .init(ino: "12", filename: "book.epub", format: "epub")
    )

    static let podcastSnapshot = LocalMediaSnapshot(
        metadata: .init(title: "The Podcast"),
        episodes: [
            .init(
                id: "ep_1",
                title: "Episode 1",
                season: "2",
                episode: "7",
                publishedAt: date,
                duration: 1800,
                chapters: [.init(id: 0, start: 0, end: 1800, title: "All")],
                track: .init(index: 1, title: "ep1.mp3", duration: 1800, startOffset: 0, mimeType: "audio/mpeg")
            )
        ]
    )

    static func connection(id: UUID = UUID(), address: String = "https://abs.example.com", userId: String = "usr_1")
        -> ServerConnectionRecord
    {
        ServerConnectionRecord(
            id: id,
            address: address,
            userId: userId,
            username: "reader",
            authMethod: .openid,
            serverVersion: "2.26.0",
            createdAt: date,
            lastUsedAt: date
        )
    }

    static func item(id: UUID = UUID(), libraryItemId: String = "li_1", title: String = "The Book")
        -> LocalLibraryItem
    {
        LocalLibraryItem(
            id: id,
            serverConnectionID: connectionID,
            serverAddress: "https://abs.example.com",
            serverUserId: "usr_1",
            libraryItemId: libraryItemId,
            mediaType: .book,
            title: title,
            authorName: "Author One",
            relativeDirectory: "li_1",
            coverRelativePath: "li_1/cover.jpg",
            coverUpdatedAt: date,
            addedAt: date,
            updatedAt: date,
            media: bookSnapshot
        )
    }

    static func file(id: UUID = UUID(), trackIndex: Int? = 1) -> LocalFile {
        LocalFile(
            id: id,
            kind: .audio,
            relativePath: "li_1/part1.mp3",
            filename: "part1.mp3",
            mimeType: "audio/mpeg",
            size: 5_000_000_000,
            serverIno: "11",
            trackIndex: trackIndex
        )
    }

    static func progress(key: String = mediaKey("li_1"), currentTime: Double = 0) -> LocalMediaProgress {
        LocalMediaProgress(
            key: key,
            serverConnectionID: connectionID,
            libraryItemId: "li_1",
            currentTime: currentTime,
            lastUpdate: date
        )
    }

    static func download(id: UUID = UUID(), key: String = mediaKey("li_2"), title: String = "Downloading")
        -> DownloadRecord
    {
        DownloadRecord(
            id: id,
            key: key,
            serverConnectionID: connectionID,
            libraryItemId: "li_2",
            mediaType: .podcast,
            title: title,
            state: .downloading,
            relativeDirectory: "li_2",
            createdAt: date,
            updatedAt: date,
            media: podcastSnapshot
        )
    }

    static func part(id: UUID = UUID()) -> DownloadPart {
        DownloadPart(
            id: id,
            kind: .audio,
            serverPath: "/api/items/li_2/file/13/download",
            filename: "ep1.mp3",
            mimeType: "audio/mpeg",
            episodeId: "ep_1",
            expectedBytes: 3_000_000_000,
            bytesWritten: 1_000,
            destinationRelativePath: "li_2/ep1.mp3",
            state: .running,
            taskIdentifier: 42,
            hasResumeData: true,
            retryCount: 1,
            lastError: "timed out"
        )
    }

    static func session(id: String = UUID().uuidString, currentTime: Double = 10) -> PendingLocalSession {
        PendingLocalSession(
            id: id,
            serverConnectionID: connectionID,
            userId: "usr_1",
            libraryItemId: "li_1",
            mediaType: .book,
            displayTitle: "The Book",
            displayAuthor: "Author One",
            duration: 1200,
            startTime: 5,
            startedAt: date,
            updatedAt: date,
            timeListening: 5,
            currentTime: currentTime
        )
    }

    static func historyEvent(id: UUID = UUID(), name: PlaybackHistoryEventName = .play) -> PlaybackHistoryEvent {
        PlaybackHistoryEvent(
            id: id,
            serverConnectionID: connectionID,
            mediaKey: mediaKey("li_1"),
            libraryItemId: "li_1",
            mediaDisplayTitle: "The Book",
            name: name,
            type: .playback,
            currentTime: 12.5,
            serverSyncAttempted: true,
            serverSyncSuccess: false,
            serverSyncMessage: "offline",
            timestamp: date
        )
    }

    /// A unique temporary directory, removed by the caller.
    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "ABSDataTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
