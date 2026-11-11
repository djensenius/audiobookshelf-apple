import ABSCore
import ABSData
import Foundation

// Maps API models to the stored snapshot here, in ABSDownloads, so ABSData stays free of them.

extension LocalMediaSnapshot {
    /// A book's snapshot: its metadata, chapters, tracks (with their inodes) and ebook.
    ///
    /// - Parameter includesCover: whether the download fetches the cover; only then is
    ///   ``coverUpdatedAt`` the item's `updatedAt`.
    init(item: LibraryItem, book: Book, includesCover: Bool) {
        let audioFiles = book.audioFiles ?? []
        self.init(
            metadata: Metadata(book.metadata),
            chapters: (book.chapters ?? []).map(Chapter.init),
            audioTracks: (book.tracks ?? []).enumerated().map { position, track in
                AudioTrack(
                    track, position: position, ino: DownloadPlanner.ino(of: track, in: audioFiles),
                    fallbackMimeType: DownloadPlanner.audioFile(for: track, in: audioFiles)?.mimeType)
            },
            ebookFile: book.ebookFile.flatMap(EbookFile.init),
            coverUpdatedAt: includesCover ? Self.date(milliseconds: item.updatedAt) : nil)
    }

    /// A podcast episode's snapshot: the podcast's metadata and only this episode.
    ///
    /// - Parameter includesCover: whether the download fetches the cover; only then is
    ///   ``coverUpdatedAt`` the item's `updatedAt`.
    init(item: LibraryItem, podcast: Podcast, episode: PodcastEpisode, includesCover: Bool) {
        let track = episode.audioTrack.map { track in
            AudioTrack(
                track, position: 0, ino: DownloadPlanner.ino(of: episode, track: track),
                fallbackMimeType: episode.audioFile?.mimeType)
        }
        self.init(
            metadata: Metadata(podcast.metadata),
            episodes: [
                Episode(
                    id: episode.id,
                    title: episode.title,
                    season: episode.season,
                    episode: episode.episode,
                    publishedAt: Self.date(milliseconds: episode.publishedAt),
                    duration: episode.duration ?? episode.audioTrack?.duration,
                    chapters: (episode.chapters ?? []).map(Chapter.init),
                    track: track)
            ],
            coverUpdatedAt: includesCover ? Self.date(milliseconds: item.updatedAt) : nil)
    }

    private static func date(milliseconds: Int?) -> Date? {
        milliseconds.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
}

extension LocalMediaSnapshot.Metadata {
    /// Authors and narrators come from the full lists, or from the flattened `authorName` and
    /// `narratorName` when those lists are missing or empty.
    init(_ metadata: BookMetadata) {
        let authors = metadata.authors?.map(\.name) ?? []
        let narrators = metadata.narrators ?? []
        self.init(
            title: metadata.title,
            subtitle: metadata.subtitle,
            authors: authors.isEmpty ? Self.names(metadata.authorName) : authors,
            narrators: narrators.isEmpty ? Self.names(metadata.narratorName) : narrators,
            series: (metadata.series ?? []).map { LocalMediaSnapshot.Series(name: $0.name, sequence: $0.sequence) },
            description: metadata.description,
            publishedYear: metadata.publishedYear,
            explicit: metadata.explicit ?? false,
            abridged: metadata.abridged ?? false)
    }

    init(_ metadata: PodcastMetadata) {
        self.init(
            title: metadata.title,
            authors: metadata.author.map { [$0] } ?? [],
            description: metadata.description,
            explicit: metadata.explicit ?? false)
    }

    /// A flattened name list as one entry. The server joins names with `, `, so splitting would
    /// break names such as `Smith, Jr.`; one entry still shows the same text, because
    /// `LocalItemStore` joins the authors with `, ` again.
    private static func names(_ list: String?) -> [String] {
        guard let list = list?.trimmingCharacters(in: .whitespaces), !list.isEmpty else { return [] }
        return [list]
    }
}

extension LocalMediaSnapshot.Chapter {
    init(_ chapter: ABSCore.Chapter) {
        self.init(id: chapter.id, start: chapter.start, end: chapter.end, title: chapter.title)
    }
}

extension LocalMediaSnapshot.AudioTrack {
    /// `position` is the track's 0-based place in its list, for servers that send no index.
    init(_ track: ABSCore.AudioTrack, position: Int, ino: String?, fallbackMimeType: String?) {
        self.init(
            index: DownloadPlanner.trackIndex(of: track, position: position),
            title: track.title ?? track.metadata?.filename ?? "",
            duration: track.duration,
            startOffset: track.startOffset ?? 0,
            mimeType: track.mimeType ?? fallbackMimeType ?? DownloadPlanner.fallbackMimeType,
            ino: ino)
    }
}

extension LocalMediaSnapshot.EbookFile {
    /// `nil` when the ebook has no filename or format to name it by.
    init?(_ ebook: ABSCore.EbookFile) {
        guard let filename = DownloadPlanner.ebookFilename(ebook) else { return nil }
        self.init(
            ino: ebook.ino, filename: filename,
            format: ebook.ebookFormat?.rawValue ?? ebook.metadata?.ext.map { String($0.drop { $0 == "." }) } ?? "")
    }
}
