import Foundation
import Network
import Synchronization

/// A reverse proxy on the loopback interface in front of the contract server, standing in for an
/// access gate such as Cloudflare Access: a request without every `required` header and value gets
/// a 403 and goes no further; the rest are forwarded to `upstream` byte for byte, so `Range`
/// requests and their 206 replies pass through unchanged. Each request is sent upstream with
/// `Connection: close` on its own connection, so every request is checked and recorded.
final class HeaderGateProxy: Sendable {
    /// A request the gate received.
    struct Request: Sendable {
        let method: String
        /// The path and query, as sent.
        let target: String
        /// Header values by lowercased name.
        let headers: [String: String]
        /// Whether it carried the required headers and was forwarded.
        let allowed: Bool
    }

    private let listener: NWListener
    private let upstream: NWEndpoint
    private let required: [String: String]
    private let queue = DispatchQueue(label: "HeaderGateProxy")
    private let state = Mutex<(requests: [Request], connections: [NWConnection])>(([], []))

    /// The requests received so far, in order.
    var requests: [Request] { state.withLock { $0.requests } }
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)")! }

    /// - Parameter upstream: an `http` server address with a host and port.
    init(upstream: URL, required: [String: String]) throws {
        guard let host = upstream.host(), let port = upstream.port.flatMap({ NWEndpoint.Port(rawValue: UInt16($0)) })
        else { throw URLError(.badURL) }
        self.upstream = .hostPort(host: NWEndpoint.Host(host), port: port)
        self.required = required
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters)
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

    /// Stops listening and closes every connection.
    func stop() {
        listener.cancel()
        for connection in state.withLock({ $0.connections }) { connection.cancel() }
    }

    private func accept(_ client: NWConnection) {
        state.withLock { $0.connections.append(client) }
        client.start(queue: queue)
        readHead(from: client, buffer: Data())
    }

    private func readHead(from client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { return client.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                handle(head, body: buffer[end.upperBound...], from: client)
            } else if isComplete || buffer.count > 65536 {
                client.cancel()
            } else {
                readHead(from: client, buffer: buffer)
            }
        }
    }

    private func handle(_ head: String, body: Data, from client: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ").map(String.init)
        var headers: [String: String] = [:]
        var forwarded = [lines[0]]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            headers[parts[0].lowercased()] = parts[1]
            if !["connection", "keep-alive", "proxy-connection"].contains(parts[0].lowercased()) {
                forwarded.append(line)
            }
        }
        let allowed = required.allSatisfy { headers[$0.key.lowercased()] == $0.value }
        let request = Request(
            method: requestLine.first ?? "", target: requestLine.count > 1 ? requestLine[1] : "", headers: headers,
            allowed: allowed)
        state.withLock { $0.requests.append(request) }
        guard allowed else {
            let reply = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            return finish(client, with: Data(reply.utf8), closing: [client])
        }
        let server = NWConnection(to: upstream, using: .tcp)
        state.withLock { $0.connections.append(server) }
        server.start(queue: queue)
        let message = Data((forwarded + ["Connection: close", "", ""]).joined(separator: "\r\n").utf8) + body
        server.send(
            content: message,
            completion: .contentProcessed { error in
                if error != nil { [client, server].forEach { $0.cancel() } }
            })
        pipe(from: server, to: client)
        watch(client, closing: server)
    }

    /// Copies the server's reply to the client, a chunk at a time, until the server closes.
    private func pipe(from server: NWConnection, to client: NWConnection) {
        server.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { return [client, server].forEach { $0.cancel() } }
            if isComplete { return finish(client, with: data, closing: [client, server]) }
            client.send(
                content: data,
                completion: .contentProcessed { [weak self] error in
                    guard error == nil else { return [client, server].forEach { $0.cancel() } }
                    self?.pipe(from: server, to: client)
                })
        }
    }

    /// Closes both sides once the client hangs up (a cancelled check, say); any bytes it sends
    /// after its request are ignored.
    private func watch(_ client: NWConnection, closing server: NWConnection) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil { return [client, server].forEach { $0.cancel() } }
            self?.watch(client, closing: server)
        }
    }

    /// Sends the last bytes and the end of the stream, then closes `connections`.
    private func finish(_ client: NWConnection, with data: Data?, closing connections: [NWConnection]) {
        client.send(
            content: data, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { _ in connections.forEach { $0.cancel() } })
    }
}
