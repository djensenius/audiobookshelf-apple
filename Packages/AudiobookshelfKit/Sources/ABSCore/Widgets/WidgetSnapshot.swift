import Foundation

/// What the Continue Listening widget shows (#89): the item last played, written by the app to
/// the App Group and read by the widget extension.
///
/// It holds no tokens, server address or cover URL: only the connection's local ID, the item's
/// IDs and text, the position and the cover's ``CoverLocator``, by which the widget finds the
/// cover in the shared ``CoverFileStore`` (ADR 0005). A legacy external cover URL may be signed
/// (`?token=`), so only its digest is kept.
public struct WidgetSnapshot: Codable, Sendable, Hashable {
    /// The saved server connection's local ID.
    public var serverID: UUID
    public var itemID: String
    /// The podcast episode; `nil` for a book.
    public var episodeID: String?
    public var title: String
    /// The book's author, or the podcast's title for an episode.
    public var author: String
    public var chapterTitle: String?
    /// The position in the whole item, in seconds.
    public var currentTime: Double
    /// The whole item's length, in seconds.
    public var duration: Double
    /// Whether play was requested when the snapshot was taken.
    public var isPlaying: Bool
    /// The item's cover file at the 300 px bucket; `nil` when it has none.
    public var cover: CoverLocator?

    public init(
        serverID: UUID, itemID: String, episodeID: String? = nil, title: String, author: String,
        chapterTitle: String? = nil, currentTime: Double, duration: Double, isPlaying: Bool, cover: CoverLocator?
    ) {
        self.serverID = serverID
        self.itemID = itemID
        self.episodeID = episodeID
        self.title = title
        self.author = author
        self.chapterTitle = chapterTitle
        self.currentTime = currentTime
        self.duration = duration
        self.isPlaying = isPlaying
        self.cover = cover
    }

    /// The fraction played, `0...1`; `0` without a duration.
    public var progress: Double {
        guard duration > 0, currentTime.isFinite else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    /// The Continue Listening widget's kind, for `WidgetCenter.reloadTimelines(ofKind:)`.
    public static let continueListeningKind = "org.davidjensenius.Audiobookshelf.ContinueListening"
    /// The play/pause control's kind, for `ControlCenter.reloadControls(ofKind:)`.
    public static let playPauseControlKind = "org.davidjensenius.Audiobookshelf.PlayPauseControl"
    /// The jump-back control's kind; it shows no state, so nothing reloads it.
    public static let jumpBackControlKind = "org.davidjensenius.Audiobookshelf.JumpBackControl"

    /// `audiobookshelf://item/<itemID>?episode=<episodeID>&server=<serverID>`, the app's deep
    /// link to the item on this connection (`DeepLink`).
    public var deepLinkURL: URL? {
        // Encodes everything but unreserved characters, so an ID's `/`, `+`, `&` or `%` survives
        // the link parser's decoding.
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encoded(_ value: String) -> String? { value.addingPercentEncoding(withAllowedCharacters: unreserved) }
        guard let item = encoded(itemID) else { return nil }
        var components = URLComponents()
        components.scheme = "audiobookshelf"
        components.host = "item"
        components.percentEncodedPath = "/" + item
        components.percentEncodedQueryItems =
            (episodeID.map { [URLQueryItem(name: "episode", value: encoded($0))] } ?? [])
            + [URLQueryItem(name: "server", value: serverID.uuidString)]
        return components.url
    }

    /// `Library/Application Support/Widgets/continue-listening.json` in the App Group container,
    /// or `nil` without one: the widget couldn't read anything else.
    ///
    /// The container counts only if this process may use it (``AppSettings/isAppGroupAvailable(_:)``,
    /// as `DataStack` checks): on macOS the container URL comes back without the entitlement too.
    public static func defaultFileURL(
        appGroup: String = AppSettings.appGroupIdentifier,
        isAppGroupAvailable: (String) -> Bool = AppSettings.isAppGroupAvailable
    ) -> URL? {
        guard isAppGroupAvailable(appGroup) else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "Library/Application Support/Widgets/continue-listening.json")
    }

    /// The snapshot at `url`, or `nil` when there is none or it doesn't decode.
    public static func read(from url: URL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Whether the play/pause control shows playing: the snapshot at `url` says play was requested.
    /// Without a snapshot (none written, signed out, no App Group) it shows paused, so a tap plays.
    public static func isPlaying(at url: URL?) -> Bool {
        url.flatMap(read(from:))?.isPlaying ?? false
    }

    /// Replaces the file at `url` atomically, creating its folder.
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
