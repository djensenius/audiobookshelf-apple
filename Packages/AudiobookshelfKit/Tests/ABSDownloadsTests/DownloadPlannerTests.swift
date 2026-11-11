import ABSAPI
import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSDownloads

@Suite struct DownloadPlannerTests {
    private typealias Fixtures = LibraryItemFixtures

    private let planner = DownloadPlanner(
        locations: DownloadLocations(root: URL(filePath: "/tmp/planner-unused", directoryHint: .isDirectory)))
    private let connection = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let bookFolder = "00000000-0000-0000-0000-0000000000A1/li_book"
    private let podcastFolder = "00000000-0000-0000-0000-0000000000A1/li_pod"
    private let coverDate = Date(timeIntervalSince1970: 1_700_000_000.123)

    private func plan(
        _ item: LibraryItem, episodeID: String? = nil, existingCoverPath: String? = nil
    ) throws(DownloadPlanError) -> DownloadRecordDTO {
        try planner.plan(
            item: item, episodeID: episodeID, connectionID: connection, existingCoverPath: existingCoverPath)
    }

    // MARK: - Books

    @Test func bookGetsItsTracksInOrderThenTheEbookThenTheCover() throws {
        let record = try plan(Fixtures.book())

        #expect(record.key == MediaKey(serverConnectionID: connection, libraryItemId: "li_book"))
        #expect(record.mediaType == .book)
        #expect(record.title == "Dune")
        #expect(record.state == .queued)
        #expect(record.relativeDirectory == bookFolder)
        #expect(record.parts.map(\.kind) == [.audio, .audio, .audio, .ebook, .cover])
        #expect(record.parts.map(\.trackIndex) == [1, 2, 3, nil, nil])
        #expect(record.parts.allSatisfy { $0.episodeId == nil && $0.state == .queued })
        #expect(
            record.parts.map(\.filename) == [
                "01 - Part One.mp3", "02 - Part Two.mp3", "03 - Part Three.mp3", "Dune.epub", "cover.jpg",
            ])
        #expect(record.parts.map(\.destinationRelativePath) == record.parts.map { "\(bookFolder)/\($0.filename)" })
        #expect(record.parts.map(\.serverIno) == ["101", "102", "103", "201", nil])
        #expect(
            record.parts.map(\.serverPath) == [
                "/api/items/li_book/file/101/download", "/api/items/li_book/file/102/download",
                "/api/items/li_book/file/103/download", "/api/items/li_book/file/201/download",
                "/api/items/li_book/cover?width=1200&format=jpeg&ts=\(Fixtures.updatedAt)",
            ])
        #expect(record.parts.map(\.expectedBytes) == [1_000, 2_000, 3_000, 4_000, 0])
        #expect(
            record.parts.map(\.mimeType) == [
                "audio/mpeg", "audio/mpeg", "audio/mpeg", "application/epub+zip", "image/jpeg",
            ])
        #expect(
            record.parts[4].serverPath == DownloadRequests.coverPath(itemID: "li_book", updatedAt: Fixtures.updatedAt))
    }

    @Test func bookWithoutACoverGetsNoCoverPartWhateverIsStoredLocally() throws {
        let record = try plan(Fixtures.book(coverPath: nil), existingCoverPath: nil)
        #expect(record.parts.map(\.kind) == [.audio, .audio, .audio, .ebook])
        #expect(record.media.coverUpdatedAt == nil)

        // A book download replaces the local item, so it fetches the cover even if one is stored.
        let again = try plan(Fixtures.book(), existingCoverPath: "\(bookFolder)/cover.jpg")
        #expect(again.parts.last?.kind == .cover)
    }

    @Test func ebookOnlyBookGetsTheEbookAlone() throws {
        let record = try plan(Fixtures.book(files: [], coverPath: nil))
        #expect(record.parts.count == 1)
        let ebook = try #require(record.parts.first)
        #expect(ebook.kind == .ebook)
        #expect(ebook.trackIndex == nil)
        #expect(ebook.destinationRelativePath == "\(bookFolder)/Dune.epub")
        #expect(ebook.expectedBytes == 4_000)
        #expect(record.media.audioTracks.isEmpty)
        #expect(
            record.media.ebookFile == LocalMediaSnapshot.EbookFile(ino: "201", filename: "Dune.epub", format: "epub"))
    }

    @Test func ebookWithoutMetadataIsNamedAfterItsFormat() throws {
        let record = try plan(Fixtures.book(files: [], ebook: EbookFile(ino: "201", ebookFormat: .pdf)))
        #expect(record.parts.map(\.filename) == ["ebook.pdf", "cover.jpg"])
        #expect(record.parts.first?.mimeType == "application/pdf")
        #expect(record.parts.first?.expectedBytes == 0)
    }

    /// Disc folders repeat `01.mp3`; the legacy app overwrote the first.
    @Test func discFoldersWithTheSameFilenameGetNumberedNames() throws {
        let record = try plan(
            Fixtures.book(
                files: [
                    .init(ino: "11", path: "/audiobooks/Long/CD1/01.mp3", size: 10),
                    .init(ino: "21", path: "/audiobooks/Long/CD2/01.mp3", size: 20),
                    .init(ino: "31", path: "/audiobooks/Long/CD3/01.MP3", size: 30),
                    .init(ino: "40", path: "/audiobooks/Long/cover.jpg", size: 40),
                ], ebook: nil))

        #expect(
            record.parts.map(\.filename) == ["01.mp3", "01 (2).mp3", "01 (3).MP3", "cover (2).jpg", "cover.jpg"])
        #expect(record.parts.map(\.serverIno) == ["11", "21", "31", "40", nil])
        #expect(Set(record.parts.map(\.destinationRelativePath)).count == record.parts.count)
    }

    @Test func inodeFallsBackToTheContentURL() throws {
        let record = try plan(
            Fixtures.book(
                files: [
                    // Not in `audioFiles`: the ino comes from the content URL.
                    .init(ino: "901", path: "/audiobooks/Dune/a.mp3", size: 1, listed: false),
                    .init(
                        ino: "ignored", path: "/audiobooks/Dune/b.mp3", size: 2,
                        contentUrl: "/api/items/li_book/file/9%2F02?x=1",
                        listed: false),
                    // Listed under the same path: the audio file's ino wins over the URL.
                    .init(
                        ino: "903", path: "/audiobooks/Dune/c.mp3", size: 3, contentUrl: "/api/items/li_book/file/999"),
                ], ebook: nil, coverPath: nil))

        #expect(record.parts.map(\.serverIno) == ["901", "9/02", "903"])
        #expect(record.parts[1].serverPath == "/api/items/li_book/file/9%2F02/download")
        #expect(record.media.audioTracks.map(\.ino) == ["901", "9/02", "903"])
    }

    @Test func trackWithoutMetadataUsesItsAudioFile() throws {
        let record = try plan(
            Fixtures.book(
                files: [.init(ino: "5", path: "/audiobooks/Dune/a.mp3", size: 7, trackHasMetadata: false)],
                ebook: nil, coverPath: nil))
        // No path to match, so the audio file is found by the ino in the content URL.
        #expect(record.parts.map(\.serverIno) == ["5"])
        #expect(record.parts.map(\.filename) == ["a.mp3"])
        #expect(record.parts.map(\.expectedBytes) == [7])
    }

    // MARK: - Podcast episodes

    @Test func episodeWithoutALocalCoverGetsItsTrackAndTheCover() throws {
        let record = try plan(Fixtures.podcast(), episodeID: "ep_2")

        #expect(record.key == MediaKey(serverConnectionID: connection, libraryItemId: "li_pod", episodeId: "ep_2"))
        #expect(record.mediaType == .podcast)
        #expect(record.title == "Episode ep_2")
        #expect(record.relativeDirectory == podcastFolder)
        #expect(record.parts.map(\.kind) == [.audio, .cover])
        let audio = record.parts[0]
        #expect(audio.episodeId == "ep_2")
        #expect(audio.trackIndex == 1)
        #expect(audio.serverIno == "302")
        #expect(audio.serverPath == "/api/items/li_pod/file/302/download")
        #expect(audio.destinationRelativePath == "\(podcastFolder)/episodes/ep_2/ep_2.mp3")
        #expect(audio.expectedBytes == 5_000)
        #expect(record.parts[1].destinationRelativePath == "\(podcastFolder)/cover.jpg")
        #expect(record.parts[1].episodeId == nil)
        #expect(record.media.coverUpdatedAt == coverDate)
    }

    @Test func episodeKeepsAnExistingLocalCover() throws {
        let record = try plan(Fixtures.podcast(), episodeID: "ep_1", existingCoverPath: "\(podcastFolder)/cover.jpg")

        #expect(record.parts.map(\.kind) == [.audio])
        #expect(record.parts[0].episodeId == "ep_1")
        // No new cover, so the stored cover's timestamp must not move forward.
        #expect(record.media.coverUpdatedAt == nil)
    }

    @Test func episodeSnapshotHasThePodcastMetadataAndOnlyThatEpisode() throws {
        let media = try plan(Fixtures.podcast(), episodeID: "ep_2").media

        #expect(media.snapshotVersion == LocalMediaSnapshot.currentVersion)
        #expect(
            media.metadata
                == LocalMediaSnapshot.Metadata(
                    title: "The Show", authors: ["Host"], description: "Talk.", explicit: true))
        #expect(media.audioTracks.isEmpty)
        #expect(media.chapters.isEmpty)
        #expect(
            media.episodes == [
                LocalMediaSnapshot.Episode(
                    id: "ep_2", title: "Episode ep_2", season: "1", episode: "2",
                    publishedAt: Date(timeIntervalSince1970: 1_690_000_000), duration: 900,
                    chapters: [.init(id: 0, start: 0, end: 900, title: "Intro")],
                    track: .init(
                        index: 1, title: "Episode ep_2", duration: 900, startOffset: 0, mimeType: "audio/mpeg",
                        ino: "302"))
            ])
    }

    // MARK: - Snapshot

    @Test func bookSnapshotFields() throws {
        let media = try plan(Fixtures.book()).media

        #expect(media.snapshotVersion == LocalMediaSnapshot.currentVersion)
        #expect(
            media.metadata
                == LocalMediaSnapshot.Metadata(
                    title: "Dune", subtitle: "Book One", authors: ["Frank Herbert"],
                    narrators: ["Scott Brick", "Orlagh Cassidy"], series: [.init(name: "Dune Saga", sequence: "1")],
                    description: "Spice.", publishedYear: "1965", explicit: false, abridged: true))
        #expect(media.chapters == [.init(id: 0, start: 0, end: 600, title: "One")])
        #expect(
            media.audioTracks == [
                .init(index: 1, title: "Part One", duration: 600, startOffset: 0, mimeType: "audio/mpeg", ino: "101"),
                .init(index: 2, title: "Part Two", duration: 600, startOffset: 600, mimeType: "audio/mpeg", ino: "102"),
                .init(
                    index: 3, title: "Part Three", duration: 600, startOffset: 1_200, mimeType: "audio/mpeg",
                    ino: "103"),
            ])
        #expect(media.ebookFile == .init(ino: "201", filename: "Dune.epub", format: "epub"))
        #expect(media.episodes.isEmpty)
        #expect(media.coverUpdatedAt == coverDate)
    }

    @Test func bookSnapshotFallsBackToFlattenedNames() throws {
        let metadata = BookMetadata(title: "T", authorName: "A One, A Two", narratorName: "N One")
        let media = try plan(Fixtures.book(metadata: metadata)).media
        #expect(media.metadata.authors == ["A One", "A Two"])
        #expect(media.metadata.narrators == ["N One"])
        #expect(media.metadata.series.isEmpty)
    }

    // MARK: - Errors

    @Test func refusesAnEpisodeOfABook() {
        #expect(throws: DownloadPlanError.notPodcast) { try plan(Fixtures.book(), episodeID: "ep_1") }
    }

    @Test func refusesAMissingEpisode() {
        #expect(throws: DownloadPlanError.episodeNotFound) { try plan(Fixtures.podcast(), episodeID: "ep_9") }
        #expect(throws: DownloadPlanError.episodeNotFound) { try plan(Fixtures.podcast(), episodeID: nil) }
    }

    @Test func refusesItemsWithNothingToDownload() {
        #expect(throws: DownloadPlanError.noDownloadableMedia) { try plan(Fixtures.book(files: [], ebook: nil)) }
        let silent = Fixtures.podcast(episodes: [Fixtures.episode(id: "ep_1", ino: "301", hasTrack: false)])
        #expect(throws: DownloadPlanError.noDownloadableMedia) { try plan(silent, episodeID: "ep_1") }
        let bare = LibraryItem(id: "li_bare", libraryId: "lib_1", mediaType: .book)
        #expect(throws: DownloadPlanError.noDownloadableMedia) { try plan(bare) }
    }

    @Test func refusesFilesItCannotNameOrLocate() {
        // No track metadata and no listed audio file: no filename.
        let unnamed = Fixtures.book(
            files: [.init(ino: "5", path: "/audiobooks/Dune/a.mp3", size: 7, listed: false, trackHasMetadata: false)])
        #expect(throws: DownloadPlanError.missingFileMetadata) { try plan(unnamed) }
        // Not listed and no `/file/<ino>` in the content URL.
        let unlocated = Fixtures.book(
            files: [.init(ino: "5", path: "/audiobooks/Dune/a.mp3", size: 7, contentUrl: "/hls/a.m3u8", listed: false)])
        #expect(throws: DownloadPlanError.missingFileMetadata) { try plan(unlocated) }
        // Not expanded: audio files but no tracks, so the planner won't fetch only the ebook.
        #expect(throws: DownloadPlanError.missingFileMetadata) { try plan(Fixtures.book(tracks: false)) }
        let nameless = Fixtures.book(files: [], ebook: EbookFile(ino: "201"))
        #expect(throws: DownloadPlanError.missingFileMetadata) { try plan(nameless) }
    }

    @Test func refusesAnUnknownMediaType() {
        let item = LibraryItem(id: "li_video", libraryId: "lib_1", mediaType: .unknown("video"))
        #expect(throws: DownloadPlanError.unknownMediaType) { try plan(item) }
    }

    @Test func refusesAnUnusableIdentifier() {
        #expect(throws: DownloadPlanError.invalidIdentifier("")) { try plan(Fixtures.book(id: "")) }
        let longEpisode = String(repeating: "e", count: 300)
        let podcast = Fixtures.podcast(episodes: [Fixtures.episode(id: longEpisode, ino: "301")])
        #expect(throws: DownloadPlanError.invalidIdentifier(longEpisode)) { try plan(podcast, episodeID: longEpisode) }
    }

    // MARK: - Helpers

    @Test(
        arguments: [
            ("/api/items/li_1/file/123", "123"),
            ("/api/items/li_1/file/123/download?token=x", "123"),
            ("/s/local/abc/file/4%205", "4 5"),
            ("/api/items/li_1/file/", nil),
            ("/api/items/li_1/cover", nil),
        ] as [(String, String?)])
    func parsesTheInodeFromAContentURL(url: String, ino: String?) {
        #expect(DownloadPlanner.ino(fromContentURL: url) == ino)
    }
}
