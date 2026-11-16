import Foundation
import Network
import Synchronization

/// A reverse proxy on the loopback interface in front of the contract server, standing in for an
/// access gate such as Cloudflare Access: a request without every `required` header and value gets
/// a 403 and goes no further. The rest go to `upstream` with their request line and headers as
/// received, except that `Connection`, `Keep-Alive` and `Proxy-Connection` are replaced with
/// `Connection: close`, so each request has its own upstream connection and is checked and
/// recorded. Replies come back unchanged, so `Range` requests and their 206 replies pass through.
/// The gate forwards no request bodies: a request with one (`Content-Length` above 0, or any
/// `Transfer-Encoding`) gets a 501. An upstream it can't reach gives a 502.
final class HeaderGateProxy: Sendable {
    /// A request the gate received.
    struct Request: Sendable {
        let method: String
        /// The path and query, as sent.
        let target: String
        /// Header values by lowercased name.
        let headers: [String: String]
        /// Whether it carried the required headers and no body, and was forwarded.
        let allowed: Bool
    }

    /// An `upstream` the gate can't forward to.
    struct UnsupportedUpstream: Error, CustomStringConvertible {
        let url: URL
        var description: String {
            "HeaderGateProxy forwards only to an http://host:port server with no path, not \(url)"
        }
    }

    private let listener: NWListener
    private let upstream: NWEndpoint
    private let required: [String: String]
    private let queue = DispatchQueue(label: "HeaderGateProxy")
    private let state = Mutex<(requests: [Request], connections: [NWConnection], stopped: Bool)>(([], [], false))

    /// The requests received so far, in order.
    var requests: [Request] { state.withLock { $0.requests } }
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)")! }

    /// - Parameter upstream: an `http` server address with a host, an explicit port and no path,
    ///   since requests are forwarded with their paths as received.
    /// - Throws: ``UnsupportedUpstream`` for any other address.
    init(upstream: URL, required: [String: String]) throws {
        let path = upstream.path(percentEncoded: true)
        guard upstream.scheme?.lowercased() == "http", path.isEmpty || path == "/", let host = upstream.host(),
            let port = upstream.port.flatMap({ UInt16(exactly: $0) }).flatMap({ NWEndpoint.Port(rawValue: $0) })
        else { throw UnsupportedUpstream(url: upstream) }
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

    /// Stops listening and closes every connection, and any opened later.
    func stop() {
        let connections = state.withLock { state in
            state.stopped = true
            return state.connections
        }
        listener.cancel()
        for connection in connections { connection.cancel() }
    }

    /// Keeps a started connection for ``stop()``; once the gate has stopped, cancels it and
    /// returns `false`.
    private func track(_ connection: NWConnection) -> Bool {
        let tracked = state.withLock { state in
            if !state.stopped { state.connections.append(connection) }
            return !state.stopped
        }
        if !tracked { connection.cancel() }
        return tracked
    }

    private func accept(_ client: NWConnection) {
        client.start(queue: queue)
        guard track(client) else { return }
        readHead(from: client, buffer: Data())
    }

    private func readHead(from client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { return client.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                handle(String(decoding: buffer[..<end.lowerBound], as: UTF8.self), from: client)
            } else if isComplete || buffer.count > 65536 {
                client.cancel()
            } else {
                readHead(from: client, buffer: buffer)
            }
        }
    }

    private func handle(_ head: String, from client: NWConnection) {
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
        let hasHeaders = required.allSatisfy { headers[$0.key.lowercased()] == $0.value }
        let hasBody =
            headers["transfer-encoding"] != nil || headers["content-length"].map { (Int($0) ?? 1) > 0 } == true
        let request = Request(
            method: requestLine.first ?? "", target: requestLine.count > 1 ? requestLine[1] : "", headers: headers,
            allowed: hasHeaders && !hasBody)
        state.withLock { $0.requests.append(request) }
        guard hasHeaders else { return reply("403 Forbidden", to: client, closing: [client]) }
        guard !hasBody else { return reply("501 Not Implemented", to: client, closing: [client]) }
        let server = NWConnection(to: upstream, using: .tcp)
        let exchange = Exchange(client: client, server: server)
        server.stateUpdateHandler = { [weak self, weak exchange] state in
            switch state {
            case .waiting, .failed: if let exchange { self?.fail(exchange) }
            default: break
            }
        }
        server.start(queue: queue)
        guard track(server) else { return client.cancel() }
        server.send(
            content: Data((forwarded + ["Connection: close", "", ""]).joined(separator: "\r\n").utf8),
            completion: .contentProcessed { [weak self] error in
                if error != nil { self?.fail(exchange) }
            })
        pipe(exchange)
        watch(exchange)
    }

    /// Copies the server's reply to the client, a chunk at a time, until the server closes.
    private func pipe(_ exchange: Exchange) {
        exchange.server.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return exchange.cancel() }
            guard error == nil else { return fail(exchange) }
            if isComplete {
                if exchange.end() != nil { finish(exchange.client, with: data, closing: exchange.connections) }
                return
            }
            guard exchange.start() else { return }
            exchange.client.send(
                content: data,
                completion: .contentProcessed { [weak self] error in
                    guard error == nil else {
                        _ = exchange.end()
                        return exchange.cancel()
                    }
                    self?.pipe(exchange)
                })
        }
    }

    /// Closes both sides once the client hangs up (a cancelled check, say); any bytes it sends
    /// after its request are ignored.
    private func watch(_ exchange: Exchange) {
        exchange.client.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] _, _, isComplete, error in
            guard isComplete || error != nil else {
                self?.watch(exchange)
                return
            }
            _ = exchange.end()
            exchange.cancel()
        }
    }

    /// The upstream failed or can't be reached: a 502, or, once the reply has started, a close.
    private func fail(_ exchange: Exchange) {
        switch exchange.end() {
        case false?: reply("502 Bad Gateway", to: exchange.client, closing: exchange.connections)
        case true?: exchange.cancel()
        case nil: break
        }
    }

    /// Answers with an empty reply of `status`, then closes `connections`.
    private func reply(_ status: String, to client: NWConnection, closing connections: [NWConnection]) {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        finish(client, with: Data(head.utf8), closing: connections)
    }

    /// Sends the last bytes and the end of the stream, then closes `connections`.
    private func finish(_ client: NWConnection, with data: Data?, closing connections: [NWConnection]) {
        client.send(
            content: data, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { _ in connections.forEach { $0.cancel() } })
    }
}

/// One forwarded request, and whether its reply to the client has started and ended, so that it
/// ends once: with the server's last bytes, a 502, or a close.
private final class Exchange: Sendable {
    let client: NWConnection
    let server: NWConnection
    private let reply = Mutex<(started: Bool, ended: Bool)>((false, false))

    var connections: [NWConnection] { [client, server] }

    init(client: NWConnection, server: NWConnection) {
        self.client = client
        self.server = server
    }

    /// Notes that the server's bytes are going to the client; `false` once the reply has ended.
    func start() -> Bool {
        reply.withLock { reply in
            reply.started = true
            return !reply.ended
        }
    }

    /// Ends the reply: `nil` if it had already ended, otherwise whether it had started.
    func end() -> Bool? {
        reply.withLock { reply in
            guard !reply.ended else { return nil }
            reply.ended = true
            return reply.started
        }
    }

    func cancel() {
        for connection in connections { connection.cancel() }
    }
}
