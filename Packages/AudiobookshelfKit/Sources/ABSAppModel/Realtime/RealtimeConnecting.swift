import ABSAPI
import ABSRealtime
import Foundation

/// The socket ``RealtimeBridge`` drives: ``SocketClient``, or a fake in tests.
public protocol RealtimeConnecting: AnyObject, Sendable {
    /// Every event, for the socket's lifetime. Read by one task.
    var events: AsyncStream<RealtimeEvent> { get }
    /// Connects, or reconnects at once; also resumes after `auth_failed`.
    func connect() async
    /// Closes the socket and stops reconnecting; with `sendingFarewell`, tells the server first.
    func disconnect(sendingFarewell: Bool) async
    /// Reconnects at once, unless idle or halted by `auth_failed`.
    func networkChanged() async
    /// Reconnects with `token`, also after `auth_failed`.
    func updateToken(_ token: String) async
}

extension SocketClient: RealtimeConnecting {}

/// Where ``RealtimeBridge`` gets the socket's access token: the session's `APIClient`, or a
/// fake in tests.
public protocol RealtimeTokenSource: Sendable {
    /// The stored access token, without a network request.
    func currentAccessToken() async -> String?
    /// A refreshed token after the socket rejected `rejected`; see
    /// `APIClient.accessToken(replacing:)`.
    func accessToken(replacing rejected: String?) async throws -> String
}

extension APIClient: RealtimeTokenSource {}
