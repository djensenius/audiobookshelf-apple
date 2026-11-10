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
    private let session: URLSession
    private let maximumMessageSize: Int

    /// `maximumMessageSize` defaults to 16 MiB: `item_added` carries expanded items and an
    /// admin's `init` lists every online user, which can exceed the 1 MiB default.
    public init(session: URLSession = .shared, maximumMessageSize: Int = 16 * 1024 * 1024) {
        self.session = session
        self.maximumMessageSize = maximumMessageSize
    }

    public func connect(url: URL, headers: [String: String]) async throws -> any WebSocketConnection {
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = maximumMessageSize
        task.resume()
        return URLSessionWebSocketConnection(task: task)
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
