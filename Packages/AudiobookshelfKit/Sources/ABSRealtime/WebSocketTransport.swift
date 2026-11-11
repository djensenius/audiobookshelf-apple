import ABSAPI
import Foundation

/// One frame received from a WebSocket.
public enum WebSocketMessage: Sendable, Equatable {
    case text(String)
    case data(Data)
}

/// Opens WebSocket connections. Production uses ``URLSessionWebSocketTransport``; tests use a fake.
public protocol WebSocketTransport: Sendable {
    func connect(url: URL, headers: [String: String]) async throws -> any WebSocketConnection
}

/// An open WebSocket.
public protocol WebSocketConnection: Sendable {
    /// Received frames. Finishes when the socket closes, or throws when receiving fails.
    var messages: AsyncThrowingStream<WebSocketMessage, any Error> { get }
    func send(_ text: String) async throws
    func close()
}

/// A ``WebSocketTransport`` over `URLSessionWebSocketTask`.
public struct URLSessionWebSocketTransport: WebSocketTransport {
    let session: URLSession
    private let maximumMessageSize: Int
    /// Invalidates an ``isolated(maximumMessageSize:)`` transport's session once every copy of
    /// the transport is released.
    private let owner: SessionOwner?

    /// A transport over `session`, which the caller owns. `maximumMessageSize` defaults to 16 MiB:
    /// `item_added` carries expanded items and an admin's `init` lists every online user, which
    /// can exceed the 1 MiB default.
    public init(session: URLSession, maximumMessageSize: Int = 16 * 1024 * 1024) {
        self.init(session: session, maximumMessageSize: maximumMessageSize, owner: nil)
    }

    private init(session: URLSession, maximumMessageSize: Int, owner: SessionOwner?) {
        self.session = session
        self.maximumMessageSize = maximumMessageSize
        self.owner = owner
    }

    /// A transport with its own session and new in-memory cookie jar (`absConnection()`, as
    /// `APIClient` uses), so cookies set during one connection's handshake, for example by a
    /// proxy, never reach another account's. The session is invalidated once the transport is
    /// released.
    public static func isolated(maximumMessageSize: Int = 16 * 1024 * 1024) -> Self {
        isolated(configuration: .absConnection(), delegate: nil, maximumMessageSize: maximumMessageSize)
    }

    static func isolated(
        configuration: URLSessionConfiguration, delegate: (any URLSessionDelegate)?, maximumMessageSize: Int
    ) -> Self {
        let configuration = configuration.copy() as? URLSessionConfiguration ?? .absConnection()
        // A new jar even when the configuration came with one, as `APIClient` does.
        configuration.httpCookieStorage = URLSessionConfiguration.ephemeral.httpCookieStorage
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        return Self(session: session, maximumMessageSize: maximumMessageSize, owner: SessionOwner(session: session))
    }

    public func connect(url: URL, headers: [String: String]) async throws -> any WebSocketConnection {
        var request = URLRequest(url: url)
        for (name, value) in SocketEndpoint.filteredHeaders(headers) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = maximumMessageSize
        task.resume()
        return URLSessionWebSocketConnection(task: task)
    }
}

private final class SessionOwner: Sendable {
    let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    deinit {
        // Lets a farewell still being sent finish; the socket's own task is already closed.
        session.finishTasksAndInvalidate()
    }
}

private struct URLSessionWebSocketConnection: WebSocketConnection {
    let task: URLSessionWebSocketTask
    let messages: AsyncThrowingStream<WebSocketMessage, any Error>

    init(task: URLSessionWebSocketTask) {
        self.task = task
        messages = AsyncThrowingStream { continuation in
            let receiver = Task {
                do {
                    while !Task.isCancelled {
                        switch try await task.receive() {
                        case .string(let text): continuation.yield(.text(text))
                        case .data(let data): continuation.yield(.data(data))
                        @unknown default: continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in receiver.cancel() }
        }
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
