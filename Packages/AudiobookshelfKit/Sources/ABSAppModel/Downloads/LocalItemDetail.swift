import ABSCore
import ABSData
import Foundation

/// What the local item screen shows of a downloaded item (legacy `pages/localMedia/item/_id.vue`):
/// its audio tracks or podcast episodes, ebook files and any other files with their sizes and
/// durations, and how it's linked to the signed-in account.
public struct LocalItemDetail: Sendable, Equatable {
    /// An audio track of a book, or an ebook or other file.
    public struct File: Sendable, Equatable, Identifiable {
        /// The local file's ID.
        public var id: UUID
        /// The track number, for audio tracks.
        public var index: Int?
        /// The track's title from the snapshot, else (also when blank) the filename.
        public var title: String
        public var filename: String
        public var mimeType: String
        /// In seconds, where the snapshot knows it.
        public var duration: Double?
        public var byteCount: Int64
        /// The ebook format, for example `epub`.
        public var format: String?
    }

    /// A downloaded podcast episode.
    public struct Episode: Sendable, Equatable, Identifiable {
        /// The server's episode ID.
        public var id: String
        public var title: String
        public var publishedAt: Date?
        /// In seconds, where the snapshot knows it.
        public var duration: Double?
        public var byteCount: Int64
    }

    /// The signed-in account, to compare with the one the item was downloaded with.
    public struct Account: Sendable, Equatable {
        public var connectionID: UUID
        public var address: String
        public var userID: String

        public init(connectionID: UUID, address: String, userID: String) {
            self.connectionID = connectionID
            self.address = address
            self.userID = userID
        }
    }

    /// How the item is linked to its server item, compared with the signed-in account (legacy
    /// `pages/item/_id/index.vue`). Progress syncs only through the account it was downloaded with.
    public enum LinkStatus: Sendable, Equatable {
        /// Downloaded with the signed-in account.
        case thisAccount
        /// Downloaded from another server address, given here.
        case otherServer(String)
        /// Downloaded from this server by another user.
        case otherUser
        /// Downloaded by this user through another saved connection to this server.
        case otherConnection
        /// Signed out: linked to the server at this address.
        case linked(String)
    }

    public var id: UUID
    public var serverConnectionID: UUID
    public var libraryItemId: String
    public var mediaType: MediaType
    public var title: String
    public var author: String?
    public var coverUpdatedAt: Date?
    /// A book's audio tracks, by track number.
    public var tracks: [File]
    /// A podcast's episodes, newest first, undated last.
    public var episodes: [Episode]
    public var ebooks: [File]
    /// Files that are neither a track, an episode nor an ebook (a podcast's audio without an episode).
    public var otherFiles: [File]
    public var link: LinkStatus

    public var isPodcast: Bool { mediaType == .podcast }
    /// The tracks' or episodes' bytes. Every sum saturates at `Int64.max`, as in ``DownloadsListing``.
    public var audioBytes: Int64 {
        Self.adding(Self.sum(tracks.map(\.byteCount)), Self.sum(episodes.map(\.byteCount)))
    }
    public var ebookBytes: Int64 { Self.sum(ebooks.map(\.byteCount)) }
    /// Every file's bytes.
    public var totalBytes: Int64 {
        Self.adding(Self.adding(audioBytes, ebookBytes), Self.sum(otherFiles.map(\.byteCount)))
    }
    /// The tracks' or episodes' seconds, where known.
    public var totalDuration: Double {
        tracks.reduce(0) { $0 + ($1.duration ?? 0) } + episodes.reduce(0) { $0 + ($1.duration ?? 0) }
    }

    /// - Parameters:
    ///   - item: the downloaded item.
    ///   - account: the signed-in account; `nil` while signed out.
    public init(item: LocalLibraryItemDTO, account: Account?) {
        id = item.id
        serverConnectionID = item.serverConnectionID
        libraryItemId = item.libraryItemId
        mediaType = item.mediaType
        title = item.title
        author = item.authorName
        coverUpdatedAt = item.coverUpdatedAt
        link = Self.link(of: item, account: account)

        let tracksByIndex = Dictionary(
            item.media.audioTracks.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        var tracks: [File] = []
        var ebooks: [File] = []
        var others: [File] = []
        var episodeFiles: [String: [LocalFileDTO]] = [:]
        for file in item.files {
            switch file.kind {
            case .ebook:
                ebooks.append(Self.file(file, format: item.media.ebookFile?.format))
            case .audio where item.mediaType == .podcast:
                if let episodeId = file.episodeId {
                    episodeFiles[episodeId, default: []].append(file)
                } else {
                    others.append(Self.file(file))
                }
            case .audio:
                let track = file.trackIndex.flatMap { tracksByIndex[$0] }
                var row = Self.file(file)
                row.index = file.trackIndex
                row.title = Self.label(track?.title, else: file.filename)
                row.duration = track?.duration
                tracks.append(row)
            }
        }
        self.tracks = tracks.sorted { ($0.index ?? .max, $0.filename) < ($1.index ?? .max, $1.filename) }
        self.ebooks = ebooks
        otherFiles = others
        episodes = item.mediaType == .podcast ? Self.episodes(item.media.episodes, files: episodeFiles) : []
    }

    /// See ``LinkStatus``. Addresses compare without case or a trailing slash.
    static func link(of item: LocalLibraryItemDTO, account: Account?) -> LinkStatus {
        guard let account else { return .linked(item.serverAddress) }
        if item.serverConnectionID == account.connectionID, item.serverUserId == account.userID { return .thisAccount }
        guard normalized(item.serverAddress) == normalized(account.address) else {
            return .otherServer(item.serverAddress)
        }
        guard item.serverUserId == account.userID else { return .otherUser }
        return item.serverConnectionID == account.connectionID ? .thisAccount : .otherConnection
    }

    private static func normalized(_ address: String) -> String {
        var address = address.lowercased()
        while address.hasSuffix("/") { address.removeLast() }
        return address
    }

    /// `title`, or `fallback` when it's missing, empty or only whitespace, so a row is never blank.
    static func label(_ title: String?, else fallback: String) -> String {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        return title
    }

    /// `a + b`, or `Int64.max` if that overflows.
    private static func adding(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : sum
    }

    /// The saturating sum of `sizes`.
    private static func sum(_ sizes: [Int64]) -> Int64 { sizes.reduce(0, adding) }

    private static func file(_ file: LocalFileDTO, format: String? = nil) -> File {
        File(
            id: file.id, index: nil, title: file.filename, filename: file.filename, mimeType: file.mimeType,
            duration: nil, byteCount: max(file.size, 0), format: format)
    }

    /// The snapshot's episodes, plus files whose episode isn't in the snapshot (titled by filename).
    private static func episodes(_ snapshot: [LocalMediaSnapshot.Episode], files: [String: [LocalFileDTO]]) -> [Episode]
    {
        func bytes(_ id: String) -> Int64 { sum(files[id, default: []].map { max($0.size, 0) }) }
        var episodes = snapshot.map {
            Episode(
                id: $0.id, title: label($0.title, else: files[$0.id]?.first?.filename ?? $0.id),
                publishedAt: $0.publishedAt, duration: $0.track?.duration ?? $0.duration,
                byteCount: bytes($0.id))
        }
        let known = Set(episodes.map(\.id))
        for (id, list) in files where !known.contains(id) {
            episodes.append(
                Episode(
                    id: id, title: list.first?.filename ?? id, publishedAt: nil, duration: nil, byteCount: bytes(id)))
        }
        return episodes.sorted { lhs, rhs in
            switch (lhs.publishedAt, rhs.publishedAt) {
            case (let left?, let right?) where left != right: left > right
            case (.some, nil): true
            case (nil, .some): false
            default: lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }
}
