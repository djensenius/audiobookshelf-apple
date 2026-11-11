import ABSCore
import ABSData
import ABSPlayback
import Foundation

/// What the player shows about the current item: title, author, chapter title and cover.
///
/// Mirrors `NowPlayingBridge`'s metadata: a book shows its display author, a podcast episode shows
/// the show's title (as the legacy app did). A ``LastPlayedRecord`` only seeds an item with nothing
/// shown yet, and a closing session, a restart or a failed load (which drop the session but keep the
/// item) keep the last text rather than blanking it.
struct PlayerDisplayInfo: Sendable, Hashable {
    var key: MediaKey
    var title: String
    var author: String
    /// The last chapter title seen for this item, or the restored record's.
    var chapterTitle: String?
    /// The item's cover at the default width bucket; views pick theirs with `with(bucket:)`.
    var coverKey: ImageKey?

    /// The live session's text. `session` must be for `key`.
    init(session: PlaybackSession, key: MediaKey) {
        self.key = key
        title = session.displayTitle ?? ""
        author = session.displayAuthor ?? ""
        if case .podcast(let show) = session.mediaMetadata {
            author = show.title
        }
        coverKey = Self.coverKey(key: key, path: session.coverPath, updatedAt: session.libraryItem?.updatedAt)
    }

    /// The restored record's text, shown until its session starts.
    init(record: LastPlayedRecord) {
        key = record.key
        title = record.title ?? ""
        author = record.author ?? ""
        chapterTitle = Self.nonEmpty(record.chapterTitle)
        coverKey = Self.coverKey(key: record.key, path: record.coverPath, updatedAt: nil)
    }

    /// The text for `key`: the matching session's, else `previous` when it is for the same item,
    /// else the matching restored record's; `nil` without an item or anything to show.
    static func resolve(
        key: MediaKey?, session: PlaybackSession?, restoredRecord: LastPlayedRecord?,
        retaining previous: PlayerDisplayInfo?
    ) -> PlayerDisplayInfo? {
        guard let key else { return nil }
        let previous = previous?.key == key ? previous : nil
        if let session, session.libraryItemId == key.libraryItemId, session.episodeId == key.episodeId {
            var info = PlayerDisplayInfo(session: session, key: key)
            info.chapterTitle = previous?.chapterTitle
            return info
        }
        if let previous { return previous }
        if let restoredRecord, restoredRecord.key == key { return PlayerDisplayInfo(record: restoredRecord) }
        return nil
    }

    /// Like `NowPlayingBridge`, no cover without a `coverPath`. An absolute `http(s)` path is
    /// loaded from that URL, as ``CoverRef`` does for list items.
    private static func coverKey(key: MediaKey, path: String?, updatedAt: Int?) -> ImageKey? {
        guard let path, !path.isEmpty else { return nil }
        var external: URL?
        if let url = URL(string: path), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            external = url
        }
        return CoverRef(entityID: key.libraryItemId, updatedAt: updatedAt, externalURL: external)
            .key(serverID: key.serverConnectionID)
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
