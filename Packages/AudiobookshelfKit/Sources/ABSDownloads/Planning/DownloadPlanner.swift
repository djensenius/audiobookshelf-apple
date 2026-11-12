import ABSAPI
import ABSCore
import ABSData
import Foundation

/// Why ``DownloadPlanner`` can't plan a download.
public enum DownloadPlanError: Error, Equatable, Sendable {
    /// An episode was asked for, but the item isn't a podcast.
    case notPodcast
    /// The podcast has no episode with the requested ID, or no episode was asked for.
    case episodeNotFound
    /// The item has nothing to download: a book without tracks or an ebook, or an episode
    /// without an audio track.
    case noDownloadableMedia
    /// A file can't be named or located on the server: it has no filename or inode, or the
    /// item isn't expanded (`expanded=1`), so its tracks are missing.
    case missingFileMetadata
    /// The item's media type is unknown to this client.
    case unknownMediaType
    /// The item or episode ID can't be used as a folder name (it is empty or too long).
    case invalidIdentifier(String)
}

/// Turns a server ``LibraryItem`` into a ``DownloadRecordDTO`` that ``DownloadEngine`` can run.
/// Pure: it touches no files and makes no requests.
///
/// - A book gets one ``DownloadPartKind/audio`` part per track, in the server's track order,
///   then an ``DownloadPartKind/ebook`` part if it has an ebook, then a
///   ``DownloadPartKind/cover`` part if it has a cover.
/// - A podcast episode gets one audio part, carrying its episode ID, and a cover part only if
///   the local item has no cover yet.
///
/// Destinations come from ``DownloadLayout``, so names that clash (`01.mp3` from two disc
/// folders) get numbered suffixes. The snapshot's ``LocalMediaSnapshot/coverUpdatedAt`` is the
/// item's `updatedAt` when the plan downloads a cover, and `nil` otherwise, so a kept cover's
/// timestamp isn't moved forward.
///
/// A plan never reserves the paths of files already stored for the item: each call starts a
/// fresh ``DownloadLayout``. That is safe while a book download replaces the item's files
/// (`LocalItemStore` matches files by path) and each episode has its own folder, but a caller
/// that adds files next to stored ones must pass their paths to
/// ``DownloadLayout/init(connectionID:libraryItemID:locations:reserving:)`` instead.
public struct DownloadPlanner: Sendable {
    private let locations: DownloadLocations

    /// - Parameter locations: checks every planned path (see ``DownloadLayout``).
    public init(locations: DownloadLocations) {
        self.locations = locations
    }

    /// The download record for `item`, or for one of its episodes.
    ///
    /// `item` must be expanded (`ItemEndpoints.item(id:)` sends `expanded=1`), so books carry
    /// `tracks` and `audioFiles` and podcasts carry `episodes`; a minified item throws
    /// ``DownloadPlanError/missingFileMetadata``.
    ///
    /// - Parameters:
    ///   - episodeID: the podcast episode to download; `nil` for a book.
    ///   - connectionID: the server connection the item belongs to.
    ///   - existingCoverPath: the item's cover that is stored or already on its way: the local
    ///     item's cover, or else the destination of a cover part in any other pending download
    ///     record for the same item (two episodes queued together must not both fetch
    ///     `cover.jpg`). A podcast episode only fetches the cover when this is `nil`; a book
    ///     always fetches it.
    /// - Throws: a ``DownloadPlanError``.
    public func plan(
        item: LibraryItem, episodeID: String?, connectionID: UUID, existingCoverPath: String?
    ) throws(DownloadPlanError) -> DownloadRecordDTO {
        var layout: DownloadLayout
        do {
            layout = try DownloadLayout(connectionID: connectionID, libraryItemID: item.id, locations: locations)
        } catch {
            throw .invalidIdentifier(item.id)
        }
        switch item.media {
        case .book(let book):
            guard episodeID == nil else { throw .notPodcast }
            return try planBook(item: item, book: book, connectionID: connectionID, layout: &layout)
        case .podcast(let podcast):
            guard let episodeID else { throw .episodeNotFound }
            // A minified podcast has no episode list to look in.
            guard let episodes = podcast.episodes else { throw .missingFileMetadata }
            guard let episode = episodes.first(where: { $0.id == episodeID }) else { throw .episodeNotFound }
            return try planEpisode(
                item: item, podcast: podcast, episode: episode, connectionID: connectionID,
                fetchCover: existingCoverPath == nil, layout: &layout)
        case nil:
            // Known media types always decode their media; only a missing payload gets here.
            if case .unknown = item.mediaType { throw .unknownMediaType }
            throw .noDownloadableMedia
        }
    }

    // MARK: - Book

    private func planBook(
        item: LibraryItem, book: Book, connectionID: UUID, layout: inout DownloadLayout
    ) throws(DownloadPlanError) -> DownloadRecordDTO {
        // An unexpanded item has audio files (or, minified, only counts) but no tracks, and a
        // minified one has only the ebook's format: don't plan a part of it, or nothing.
        let hasUnlistedAudio =
            !(book.audioFiles ?? []).isEmpty || (book.numTracks ?? 0) > 0 || (book.numAudioFiles ?? 0) > 0
        if book.tracks == nil, hasUnlistedAudio { throw .missingFileMetadata }
        if book.ebookFile == nil, book.ebookFormat != nil { throw .missingFileMetadata }
        let tracks = book.tracks ?? []
        guard !tracks.isEmpty || book.ebookFile != nil else { throw .noDownloadableMedia }

        var parts: [DownloadPartDTO] = []
        for (position, track) in tracks.enumerated() {
            let audioFile = Self.audioFile(for: track, in: book.audioFiles ?? [])
            guard let ino = Self.ino(of: track, in: book.audioFiles ?? []),
                let filename = track.metadata?.filename ?? audioFile?.metadata?.filename
            else { throw .missingFileMetadata }
            let destination = try Self.layoutPath { () throws in try layout.bookFilePath(filename: filename) }
            parts.append(
                DownloadPartDTO(
                    kind: .audio,
                    serverPath: DownloadRequests.filePath(itemID: item.id, ino: ino),
                    filename: Self.lastComponent(of: destination),
                    mimeType: track.mimeType ?? audioFile?.mimeType ?? Self.fallbackMimeType,
                    serverIno: ino,
                    trackIndex: Self.trackIndex(of: track, position: position),
                    expectedBytes: Int64(track.metadata?.size ?? audioFile?.metadata?.size ?? 0),
                    destinationRelativePath: destination))
        }
        if let ebook = book.ebookFile {
            // A blank inode (legacy `ino: null`) has no `/file/<ino>` to fetch.
            guard !ebook.ino.isEmpty, let filename = Self.ebookFilename(ebook) else { throw .missingFileMetadata }
            let destination = try Self.layoutPath { () throws in try layout.bookFilePath(filename: filename) }
            parts.append(
                DownloadPartDTO(
                    kind: .ebook,
                    serverPath: DownloadRequests.filePath(itemID: item.id, ino: ebook.ino),
                    filename: Self.lastComponent(of: destination),
                    mimeType: Self.ebookMimeType(ebook),
                    serverIno: ebook.ino,
                    expectedBytes: Int64(ebook.metadata?.size ?? 0),
                    destinationRelativePath: destination))
        }
        let cover = try coverPart(item: item, hasCover: book.coverPath?.isEmpty == false, layout: layout)
        if let cover { parts.append(cover) }
        return DownloadRecordDTO(
            key: MediaKey(serverConnectionID: connectionID, libraryItemId: item.id),
            mediaType: .book,
            title: book.metadata.title,
            relativeDirectory: layout.folder,
            media: LocalMediaSnapshot(item: item, book: book, includesCover: cover != nil),
            parts: parts)
    }

    // MARK: - Podcast episode

    private func planEpisode(
        item: LibraryItem, podcast: Podcast, episode: PodcastEpisode, connectionID: UUID, fetchCover: Bool,
        layout: inout DownloadLayout
    ) throws(DownloadPlanError) -> DownloadRecordDTO {
        guard let track = episode.audioTrack else { throw .noDownloadableMedia }
        guard let ino = Self.ino(of: episode, track: track),
            let filename = track.metadata?.filename ?? episode.audioFile?.metadata?.filename
        else { throw .missingFileMetadata }
        let destination = try Self.layoutPath { () throws in
            try layout.episodeFilePath(episodeID: episode.id, filename: filename)
        }
        var parts = [
            DownloadPartDTO(
                kind: .audio,
                serverPath: DownloadRequests.filePath(itemID: item.id, ino: ino),
                filename: Self.lastComponent(of: destination),
                mimeType: track.mimeType ?? episode.audioFile?.mimeType ?? Self.fallbackMimeType,
                serverIno: ino,
                trackIndex: Self.trackIndex(of: track, position: 0),
                episodeId: episode.id,
                expectedBytes: Int64(track.metadata?.size ?? episode.audioFile?.metadata?.size ?? episode.size ?? 0),
                destinationRelativePath: destination)
        ]
        let cover = try coverPart(
            item: item, hasCover: fetchCover && podcast.coverPath?.isEmpty == false, layout: layout)
        if let cover { parts.append(cover) }
        return DownloadRecordDTO(
            key: MediaKey(serverConnectionID: connectionID, libraryItemId: item.id, episodeId: episode.id),
            mediaType: .podcast,
            title: episode.title.isEmpty ? podcast.metadata.title : episode.title,
            relativeDirectory: layout.folder,
            media: LocalMediaSnapshot(item: item, podcast: podcast, episode: episode, includesCover: cover != nil),
            parts: parts)
    }

    // MARK: - Shared

    /// The offline cover (ADR 0005), or `nil` when `hasCover` is false.
    private func coverPart(
        item: LibraryItem, hasCover: Bool, layout: DownloadLayout
    ) throws(DownloadPlanError) -> DownloadPartDTO? {
        guard hasCover else { return nil }
        let destination = try Self.layoutPath { () throws in try layout.coverPath() }
        return DownloadPartDTO(
            kind: .cover,
            serverPath: DownloadRequests.coverPath(itemID: item.id, updatedAt: item.updatedAt ?? 0),
            filename: DownloadLayout.coverFilename,
            mimeType: "image/jpeg",
            destinationRelativePath: destination)
    }

    /// The MIME type of a file the server gives none for.
    static let fallbackMimeType = "application/octet-stream"

    /// Runs a ``DownloadLayout`` call; the only error it can raise once the layout exists is an
    /// unusable episode ID.
    private static func layoutPath(_ body: () throws -> String) throws(DownloadPlanError) -> String {
        do {
            return try body()
        } catch DownloadLayout.LayoutError.invalidIdentifier(let id) {
            throw .invalidIdentifier(id)
        } catch {
            // Unreachable today: escaped IDs and sanitised filenames always form a valid relative
            // path, and nothing is reserved, so `unrelatedPath` and `PathError` can't occur. If
            // they ever do, the server's file data couldn't be placed, which is closest to
            // missing metadata.
            throw .missingFileMetadata
        }
    }

    /// The name a ``DownloadLayout`` path ends in, after any collision suffix.
    private static func lastComponent(of path: String) -> String {
        // Scalars, not Characters, as in ``DownloadLayout``.
        guard let slash = path.unicodeScalars.lastIndex(of: "/") else { return path }
        return String(Substring(path.unicodeScalars[path.unicodeScalars.index(after: slash)...]))
    }

    /// The track's 1-based index; servers 2.26.0–2.26.2 may send `null` for episode tracks.
    static func trackIndex(of track: AudioTrack, position: Int) -> Int {
        track.index ?? position + 1
    }

    /// The book audio file `track` plays: the one at the same server path, or else the one
    /// whose inode is in the track's content URL.
    static func audioFile(for track: AudioTrack, in audioFiles: [AudioFile]) -> AudioFile? {
        if let path = track.metadata?.path, let file = audioFiles.first(where: { $0.metadata?.path == path }) {
            return file
        }
        guard let ino = track.contentUrl.flatMap(ino(fromContentURL:)) else { return nil }
        return audioFiles.first { $0.ino == ino }
    }

    /// The inode of a book track: its audio file's, or the `<ino>` in a
    /// `/api/items/<id>/file/<ino>` content URL.
    static func ino(of track: AudioTrack, in audioFiles: [AudioFile]) -> String? {
        audioFile(for: track, in: audioFiles)?.ino ?? track.contentUrl.flatMap(ino(fromContentURL:))
    }

    /// The inode of an episode's file: its audio file's, or the `<ino>` in its track's content URL.
    static func ino(of episode: PodcastEpisode, track: AudioTrack) -> String? {
        episode.audioFile?.ino ?? track.contentUrl.flatMap(ino(fromContentURL:))
    }

    /// The `<ino>` after the last `file` component of `contentURL`'s path, percent-decoded.
    static func ino(fromContentURL contentURL: String) -> String? {
        let path = contentURL.prefix { $0 != "?" && $0 != "#" }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = components.dropLast().lastIndex(of: "file") else { return nil }
        let ino = String(components[index + 1])
        let decoded = ino.removingPercentEncoding ?? ino
        return decoded.isEmpty ? nil : decoded
    }

    /// The ebook's MIME type, from its format or else its extension.
    static func ebookMimeType(_ ebook: EbookFile) -> String {
        let fromExtension = ebook.metadata?.ext.flatMap {
            EbookFormat(rawValue: String($0.drop { $0 == "." })).mimeType
        }
        return ebook.ebookFormat?.mimeType ?? fromExtension ?? fallbackMimeType
    }

    /// The ebook's server filename, or `ebook.<format>` as the legacy app named it.
    static func ebookFilename(_ ebook: EbookFile) -> String? {
        if let filename = ebook.metadata?.filename, !filename.isEmpty { return filename }
        return ebook.ebookFormat.map { "ebook.\($0.rawValue)" }
    }
}
