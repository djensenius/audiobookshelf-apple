import Foundation
import Network
import Synchronization

/// A minimal HTTP/1.1 server on the loopback interface, for tests that need a real
/// `URLSession` transfer (genuine resume data, say). Each request's head is read up to its
/// blank line and handed to `respond`; the reply is sent and the connection is left open, so a
/// body shorter than its `Content-Length` stalls the transfer until the client cancels.
final class LoopbackHTTPServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackHTTPServer")
    private let state = Mutex<(connections: Int, requests: [String])>((0, []))
    private let respond: @Sendable (String) -> Data

    /// The request heads received so far, in order.
    var requests: [String] { state.withLock { $0.requests } }
    /// How many connections were accepted.
    var connections: Int { state.withLock { $0.connections } }
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init(respond: @escaping @Sendable (String) -> Data) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters)
        self.respond = respond
    }

    /// Starts listening; returns once the port is bound.
    func start() async throws {
        let (ready, readyContinuation) = AsyncThrowingStream<Void, any Error>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: readyContinuation.finish()
            case .failed(let error): readyContinuation.finish(throwing: error)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        for try await _ in ready {}
    }

    func stop() {
        listener.cancel()
    }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    private func accept(_ connection: NWConnection) {
        state.withLock { $0.connections += 1 }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                state.withLock { $0.requests.append(head) }
                connection.send(content: respond(head), completion: .idempotent)
            } else if !isComplete {
                receive(on: connection, buffer: buffer)
            }
        }
    }
}

extension String {
    /// The value of the HTTP header `name` in this request head, matched case-insensitively.
    func httpHeader(_ name: String) -> String? {
        split(separator: "\r\n").dropFirst().lazy.compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased()
            else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }.first
    }
}
