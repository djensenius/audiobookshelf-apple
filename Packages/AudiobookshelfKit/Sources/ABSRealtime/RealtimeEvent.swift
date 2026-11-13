import ABSCore
import Foundation

/// Why the socket disconnected.
public enum RealtimeDisconnectReason: Sendable, Equatable {
    /// `disconnect()` was called.
    case clientRequested
    /// The WebSocket closed or failed.
    case transportClosed
    /// The server sent an Engine.IO close or a Socket.IO disconnect.
    case serverClosed
    /// No Engine.IO ping arrived within `pingInterval + pingTimeout`.
    case pingTimeout
    /// The server rejected the namespace connection (`44`). Reported even when `.connected` was
    /// never emitted for this connection.
    case connectError(message: String?)
    case authFailed
    case networkChanged
    case tokenUpdated
}

/// The `init` payload sent once the socket is authenticated.
public struct RealtimeSession: Sendable, Hashable, Decodable {
    public var userId: String
    public var username: String

    public init(userId: String, username: String) {
        self.userId = userId
        self.username = username
    }
}

/// The `user_item_progress_updated` payload: `{id, sessionId, deviceDescription, data}`.
public struct UserItemProgressUpdate: Sendable, Hashable, Decodable {
    /// The media progress ID.
    public var id: String
    public var sessionId: String?
    public var deviceDescription: String?
    public var progress: MediaProgress

    public init(id: String, sessionId: String?, deviceDescription: String?, progress: MediaProgress) {
        self.id = id
        self.sessionId = sessionId
        self.deviceDescription = deviceDescription
        self.progress = progress
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionId, deviceDescription
        case progress = "data"
    }
}

/// An entity of one library that the server added, updated or removed: `<entity>_added`,
/// `<entity>_updated` and `<entity>_removed`, for authors, collections and playlists.
public enum LibraryEntityChange<Entity: Sendable & Hashable>: Sendable, Hashable {
    case added(Entity, libraryID: String)
    case updated(Entity, libraryID: String)
    /// Removals may carry only `{id, libraryId}`, so only the ID is kept.
    case removed(id: String, libraryID: String)

    public var libraryID: String {
        switch self {
        case .added(_, let libraryID), .updated(_, let libraryID), .removed(_, let libraryID): libraryID
        }
    }
}

/// An RSS feed was opened or closed. The server sends both to every user, with the feed as
/// `Feed.toOldJSONMinified`.
public enum RssFeedChange: Sendable, Hashable {
    case opened(RssFeed)
    case closed(RssFeed)

    public var feed: RssFeed {
        switch self {
        case .opened(let feed), .closed(let feed): feed
        }
    }
}

/// The `stream_reset` payload, `{startTime, streamId}`: the server restarted an HLS transcode
/// (`HlsRouter`). It goes to every socket, so it applies only where `streamId` is the playing
/// session's ID, which is a capability (ADR 0007): never log it.
public struct StreamReset: Sendable, Hashable, Decodable {
    /// The server stream's ID, which is its playback session's.
    public var streamId: String
    /// Where the transcode restarted, in seconds. Only a signal: recovery seeks to its own target.
    public var startTime: Double?

    public init(streamId: String, startTime: Double? = nil) {
        self.streamId = streamId
        self.startTime = startTime
    }
}

public enum RealtimeEvent: Sendable, Equatable {
    /// The Socket.IO namespace connection was accepted. Not yet authenticated.
    case connected
    case disconnected(RealtimeDisconnectReason)
    /// The `auth` event succeeded.
    case initialized(RealtimeSession)
    /// The server rejected the token, e.g. "Token expired". Reconnecting stops until the token
    /// is updated or `connect()` is called.
    case authFailed(message: String?)
    case userUpdated(User)
    case userItemProgressUpdated(UserItemProgressUpdate)
    /// `collection_added`, `collection_updated` or `collection_removed`.
    case collectionChanged(LibraryEntityChange<LibraryCollection>)
    /// `playlist_added`, `playlist_updated` or `playlist_removed`; `userID` is the playlist's owner.
    case playlistChanged(LibraryEntityChange<Playlist>, userID: String)
    /// `author_added`, `author_updated` or `author_removed`.
    case authorChanged(LibraryEntityChange<Author>)
    /// `rss_feed_open` or `rss_feed_closed`.
    case rssFeedChanged(RssFeedChange)
    /// `stream_reset`, for any user's stream.
    case streamReset(StreamReset)
}

extension RealtimeEvent {
    static let initEvent = "init"
    static let authFailedEvent = "auth_failed"

    /// Decodes a server event from its JSON argument array. Returns `nil` for events this client
    /// doesn't handle; throws when a handled event has a malformed payload.
    static func decode(name: String, arguments: Data) throws -> RealtimeEvent? {
        switch name {
        case initEvent:
            return .initialized(try argument(RealtimeSession.self, from: arguments))
        case authFailedEvent:
            let payload = try? argument(AuthFailedPayload.self, from: arguments)
            return .authFailed(message: payload?.message)
        case "user_updated":
            return .userUpdated(try argument(User.self, from: arguments))
        case "user_item_progress_updated":
            return .userItemProgressUpdated(try argument(UserItemProgressUpdate.self, from: arguments))
        case "collection_added":
            let collection = try argument(LibraryCollection.self, from: arguments)
            return .collectionChanged(.added(collection, libraryID: collection.libraryId))
        case "collection_updated":
            let collection = try argument(LibraryCollection.self, from: arguments)
            return .collectionChanged(.updated(collection, libraryID: collection.libraryId))
        case "collection_removed":
            let removed = try argument(LibraryScoped<EntityID>.self, from: arguments)
            return .collectionChanged(.removed(id: removed.value.id, libraryID: removed.libraryID))
        case "playlist_added":
            let playlist = try argument(Owned<Playlist>.self, from: arguments)
            return .playlistChanged(
                .added(playlist.value, libraryID: playlist.value.libraryId), userID: playlist.userID)
        case "playlist_updated":
            let playlist = try argument(Owned<Playlist>.self, from: arguments)
            return .playlistChanged(
                .updated(playlist.value, libraryID: playlist.value.libraryId), userID: playlist.userID)
        case "playlist_removed":
            let removed = try argument(Owned<LibraryScoped<EntityID>>.self, from: arguments)
            return .playlistChanged(
                .removed(id: removed.value.value.id, libraryID: removed.value.libraryID), userID: removed.userID)
        case "author_added":
            let author = try argument(LibraryScoped<Author>.self, from: arguments)
            return .authorChanged(.added(author.value, libraryID: author.libraryID))
        case "author_updated":
            let author = try argument(LibraryScoped<Author>.self, from: arguments)
            return .authorChanged(.updated(author.value, libraryID: author.libraryID))
        case "author_removed":
            let removed = try argument(LibraryScoped<EntityID>.self, from: arguments)
            return .authorChanged(.removed(id: removed.value.id, libraryID: removed.libraryID))
        case "rss_feed_open":
            return .rssFeedChanged(.opened(try argument(RssFeed.self, from: arguments)))
        case "rss_feed_closed":
            return .rssFeedChanged(.closed(try argument(RssFeed.self, from: arguments)))
        case "stream_reset":
            return .streamReset(try argument(StreamReset.self, from: arguments))
        default:
            return nil
        }
    }

    private static func argument<Value: Decodable>(_ type: Value.Type, from arguments: Data) throws -> Value {
        try JSONDecoder().decode(EventArgument<Value>.self, from: arguments).value
    }
}

private struct AuthFailedPayload: Decodable {
    let message: String?
}

/// A payload that must name its library in `libraryId`, decoded alongside the value itself.
private struct LibraryScoped<Value: Decodable>: Decodable {
    let value: Value
    let libraryID: String

    private enum CodingKeys: String, CodingKey {
        case libraryId
    }

    init(from decoder: any Decoder) throws {
        value = try Value(from: decoder)
        libraryID = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .libraryId)
    }
}

/// A payload that must name its owner in `userId`, decoded alongside the value itself.
private struct Owned<Value: Decodable>: Decodable {
    let value: Value
    let userID: String

    private enum CodingKeys: String, CodingKey {
        case userId
    }

    init(from decoder: any Decoder) throws {
        value = try Value(from: decoder)
        userID = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .userId)
    }
}

private struct EntityID: Decodable {
    let id: String
}
