import ABSCore
import Foundation

/// Expanded library items for planner tests, built in code (the test target has no fixtures).
enum LibraryItemFixtures {
    /// `updatedAt` of every fixture item, in epoch milliseconds.
    static let updatedAt = 1_700_000_000_123

    /// A book track and its audio file, which share a server path.
    struct BookFile {
        var ino: String
        var path: String
        var size: Int
        var title: String? = nil
        var duration: Double = 600
        /// Overrides the track's `/api/items/<id>/file/<ino>` content URL.
        var contentUrl: String? = nil
        /// Whether `audioFiles` lists this file.
        var listed = true
        /// Whether the track carries file metadata.
        var trackHasMetadata = true
        /// The track's index; `nil` uses its 1-based position.
        var index: Int? = nil
        var trackMimeType: String? = "audio/mpeg"
        var fileMimeType: String? = "audio/mpeg"

        var filename: String { String(path.split(separator: "/").last ?? "") }
    }

    static func book(
        id: String = "li_book",
        files: [BookFile] = defaultBookFiles,
        tracks hasTracks: Bool = true,
        ebook: EbookFile? = epub,
        coverPath: String? = "/metadata/items/li_book/cover.jpg",
        chapters: [Chapter] = [Chapter(id: 0, start: 0, end: 600, title: "One")],
        metadata: BookMetadata = bookMetadata,
        updatedAt: Int? = LibraryItemFixtures.updatedAt
    ) -> LibraryItem {
        var offset = 0.0
        let tracks = files.enumerated().map { position, file in
            defer { offset += file.duration }
            return AudioTrack(
                index: file.index ?? position + 1, startOffset: offset, duration: file.duration, title: file.title,
                contentUrl: file.contentUrl ?? "/api/items/\(id)/file/\(file.ino)", mimeType: file.trackMimeType,
                codec: "mp3",
                metadata: file.trackHasMetadata ? fileMetadata(path: file.path, size: file.size) : nil)
        }
        let audioFiles = files.enumerated().filter(\.element.listed).map { position, file in
            AudioFile(
                index: position + 1, ino: file.ino, metadata: fileMetadata(path: file.path, size: file.size),
                duration: file.duration, mimeType: file.fileMimeType)
        }
        let book = Book(
            id: "book_1", libraryItemId: id, metadata: metadata, coverPath: coverPath, audioFiles: audioFiles,
            chapters: chapters, ebookFile: ebook, tracks: hasTracks ? tracks : nil)
        return LibraryItem(
            id: id, libraryId: "lib_1", updatedAt: updatedAt, mediaType: .book, media: .book(book))
    }

    static let defaultBookFiles = [
        BookFile(ino: "101", path: "/audiobooks/Dune/01 - Part One.mp3", size: 1_000, title: "Part One"),
        BookFile(ino: "102", path: "/audiobooks/Dune/02 - Part Two.mp3", size: 2_000, title: "Part Two"),
        BookFile(ino: "103", path: "/audiobooks/Dune/03 - Part Three.mp3", size: 3_000, title: "Part Three"),
    ]

    static let epub = EbookFile(
        ino: "201", metadata: fileMetadata(path: "/audiobooks/Dune/Dune.epub", size: 4_000), ebookFormat: .epub)

    static let bookMetadata = BookMetadata(
        title: "Dune", subtitle: "Book One",
        authors: [Author(id: "au_1", name: "Frank Herbert")], narrators: ["Scott Brick", "Orlagh Cassidy"],
        series: [Series(id: "se_1", name: "Dune Saga", sequence: "1")], publishedYear: "1965",
        description: "Spice.", explicit: false, abridged: true)

    static func podcast(
        id: String = "li_pod",
        episodes: [PodcastEpisode] = [episode(id: "ep_1", ino: "301"), episode(id: "ep_2", ino: "302")],
        coverPath: String? = "/metadata/items/li_pod/cover.jpg",
        numEpisodes: Int? = nil
    ) -> LibraryItem {
        let podcast = Podcast(
            id: "pod_1", libraryItemId: id,
            metadata: PodcastMetadata(title: "The Show", author: "Host", description: "Talk.", explicit: true),
            coverPath: coverPath, episodes: numEpisodes == nil ? episodes : nil, numEpisodes: numEpisodes)
        return LibraryItem(
            id: id, libraryId: "lib_2", updatedAt: updatedAt, mediaType: .podcast, media: .podcast(podcast))
    }

    /// The track's content URL names `url-<ino>`, a different inode from the audio file's, so
    /// tests see which one the planner uses.
    static func episode(
        id: String, ino: String, hasTrack: Bool = true, hasAudioFile: Bool = true, itemID: String = "li_pod"
    ) -> PodcastEpisode {
        let path = "/podcasts/The Show/\(id).mp3"
        let metadata = fileMetadata(path: path, size: 5_000)
        // Without an audio file, the track's metadata has no size either, as on some servers.
        let trackMetadata = hasAudioFile ? metadata : FileMetadata(filename: "\(id).mp3", path: path)
        return PodcastEpisode(
            id: id, libraryItemId: itemID, season: "1", episode: "2", title: "Episode \(id)",
            chapters: [Chapter(id: 0, start: 0, end: 900, title: "Intro")],
            audioFile: hasAudioFile
                ? AudioFile(ino: ino, metadata: metadata, duration: 900, mimeType: "audio/mpeg") : nil,
            audioTrack: hasTrack
                ? AudioTrack(
                    index: nil, startOffset: 0, duration: 900, title: "Episode \(id)",
                    contentUrl: "/api/items/\(itemID)/file/url-\(ino)", mimeType: "audio/mpeg",
                    metadata: trackMetadata)
                : nil,
            publishedAt: 1_690_000_000_000, duration: 900, size: 4_321)
    }

    static func fileMetadata(path: String, size: Int) -> FileMetadata {
        let filename = String(path.split(separator: "/").last ?? "")
        return FileMetadata(
            filename: filename, ext: "." + (filename.split(separator: ".").last.map(String.init) ?? ""), path: path,
            size: size)
    }
}
