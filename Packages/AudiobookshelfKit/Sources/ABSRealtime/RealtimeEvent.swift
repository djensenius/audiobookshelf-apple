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
    case playlistAdded(Playlist)
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
        case "playlist_added":
            return .playlistAdded(try argument(Playlist.self, from: arguments))
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
