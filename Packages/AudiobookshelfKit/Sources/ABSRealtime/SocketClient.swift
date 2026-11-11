import Foundation
import os

/// Where and how ``SocketClient`` connects.
public struct RealtimeConfiguration: Sendable {
    /// The server address the user entered, including any subpath, e.g. `https://host/abs`.
    public var serverAddress: URL
    /// The access token sent with the `auth` event.
    public var token: String?
    /// User-configured headers for reverse proxies. `Authorization` and `Cookie` are dropped.
    public var customHeaders: [String: String]

    public init(serverAddress: URL, token: String?, customHeaders: [String: String] = [:]) {
        self.serverAddress = serverAddress
        self.token = token
        self.customHeaders = customHeaders
    }
}

public enum RealtimeError: Error, Sendable, Equatable {
    case invalidServerAddress
}

/// A minimal websocket-only Socket.IO v4 client for the Audiobookshelf server.
///
/// It answers Engine.IO pings, connects the main namespace, sends `auth` with the token, and
/// reconnects with backoff after errors and ping timeouts. `auth_failed` stops reconnecting until
/// ``updateToken(_:)`` or ``connect()`` is called.
public actor SocketClient {
    /// The namespace connection (`40`) must be accepted within this time of opening the socket,
    /// as socket.io-client's default `timeout`; server pings alone don't keep it alive.
    static let connectTimeout: Duration = .seconds(20)
    /// How long the best-effort `41` may take before the old socket is closed anyway.
    static let farewellTimeout: Duration = .seconds(1)

    private enum Mode {
        case idle
        case active
        case haltedByAuthFailure
    }

    private enum Deadline {
        /// Until the namespace connection is accepted.
        case connect
        /// Until the next Engine.IO ping.
        case liveness
    }

    private static let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "realtime")

    public nonisolated let events: AsyncStream<RealtimeEvent>
    private let continuation: AsyncStream<RealtimeEvent>.Continuation

    private let url: URL
    private let headers: [String: String]
    private var token: String?
    private let transport: any WebSocketTransport
    private let clock: any Clock<Duration>
    private let random: @Sendable () -> Double
    private let backoff = ReconnectBackoff()

    private var mode = Mode.idle
    /// Incremented whenever the current connection is replaced, so callbacks from older
    /// connections are ignored.
    private var generation = 0
    private var connection: (any WebSocketConnection)?
    private var isConnected = false
    private var livenessTimeout: Duration?
    private var receiveTask: Task<Void, Never>?
    private var deadlines: [Deadline: (id: Int, task: Task<Void, Never>)] = [:]
    private var nextDeadlineID = 0
    private var reconnectTask: Task<Void, Never>?
    private var reconnectID = 0
    private var attempt = 0

    /// - Parameters:
    ///   - clock: Times heartbeats and reconnect backoff.
    ///   - random: Returns a value in `0..<1` for backoff jitter.
    public init(
        configuration: RealtimeConfiguration,
        transport: any WebSocketTransport = URLSessionWebSocketTransport(),
        clock: any Clock<Duration> = ContinuousClock(),
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) throws(RealtimeError) {
        guard let url = SocketEndpoint.url(forServerAddress: configuration.serverAddress) else {
            throw .invalidServerAddress
        }
        self.url = url
        headers = SocketEndpoint.filteredHeaders(configuration.customHeaders)
        token = configuration.token
        self.transport = transport
        self.clock = clock
        self.random = random
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    deinit {
        receiveTask?.cancel()
        for deadline in deadlines.values { deadline.task.cancel() }
        reconnectTask?.cancel()
        connection?.close()
        continuation.finish()
    }

    /// Connects, or reconnects immediately if already connected. Resets the backoff and resumes
    /// after an `auth_failed`. Without a token the client opens no socket and connects as soon
    /// as ``updateToken(_:)`` supplies one.
    public func connect() async {
        mode = .active
        await reconnectNow(reason: .clientRequested)
    }

    /// Closes the socket and stops reconnecting.
    /// - Parameter sendingFarewell: Whether to tell the server with a `41` first. Pass `false`
    ///   when nothing may be sent, for example after the session expired.
    public func disconnect(sendingFarewell: Bool = true) {
        mode = .idle
        cancelReconnect()
        // All state changes happen before anything is awaited, so a `connect()` can't interleave
        // with a half-finished disconnect. The farewell `41` is sent off the actor.
        let farewell = sendingFarewell && isConnected ? connection : nil
        if farewell != nil { connection = nil }
        tearDown(reason: .clientRequested)
        if let farewell {
            let packet = Self.wrap(.disconnect())
            let clock = clock
            Task.detached {
                // Closes after the send finishes or the timeout passes, whichever is first; closing
                // also ends a stalled send.
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { try? await farewell.send(packet) }
                    group.addTask { try? await clock.sleep(for: SocketClient.farewellTimeout) }
                    await group.next()
                    farewell.close()
                    group.cancelAll()
                }
            }
        }
    }

    /// Reconnects immediately with a reset backoff, unless the client is idle or halted by
    /// `auth_failed`.
    public func networkChanged() async {
        guard mode == .active else { return }
        await reconnectNow(reason: .networkChanged)
    }

    /// Stores a new access token and reconnects with it immediately, also after `auth_failed`.
    /// An idle client only stores the token.
    public func updateToken(_ token: String) async {
        self.token = token
        guard mode != .idle else { return }
        mode = .active
        await reconnectNow(reason: .tokenUpdated)
    }

    // MARK: - Connection lifecycle

    private func reconnectNow(reason: RealtimeDisconnectReason) async {
        cancelReconnect()
        attempt = 0
        tearDown(reason: reason)
        await open()
    }

    private func open() async {
        guard token != nil else {
            Self.logger.notice("No token; the socket connects once one is set")
            return
        }
        generation += 1
        let generation = generation
        let connection: any WebSocketConnection
        do {
            connection = try await transport.connect(url: url, headers: headers)
        } catch {
            guard generation == self.generation, mode == .active else { return }
            Self.logger.error("Socket connect failed: \(error.localizedDescription, privacy: .public)")
            scheduleReconnect()
            return
        }
        guard generation == self.generation, mode == .active else {
            connection.close()
            return
        }
        self.connection = connection
        startDeadline(.connect, after: Self.connectTimeout)
        receiveTask = Task { [weak self] in
            do {
                for try await message in connection.messages {
                    await self?.receive(message, generation: generation)
                }
            } catch {
                Self.logger.info("Socket receive failed: \(error.localizedDescription, privacy: .public)")
            }
            await self?.connectionEnded(generation: generation)
        }
    }

    /// Closes the current connection without scheduling a reconnect, and reports `reason` if the
    /// namespace was connected.
    private func tearDown(reason: RealtimeDisconnectReason) {
        if closeConnection() {
            continuation.yield(.disconnected(reason))
        }
    }

    /// Returns whether the namespace was connected.
    private func closeConnection() -> Bool {
        generation += 1
        receiveTask?.cancel()
        receiveTask = nil
        for deadline in deadlines.values { deadline.task.cancel() }
        deadlines = [:]
        connection?.close()
        connection = nil
        livenessTimeout = nil
        defer { isConnected = false }
        return isConnected
    }

    private func connectionEnded(generation: Int) {
        guard generation == self.generation else { return }
        tearDown(reason: .transportClosed)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard mode == .active else { return }
        cancelReconnect()
        let delay = backoff.delay(attempt: attempt, random: random())
        attempt += 1
        let id = reconnectID
        let clock = clock
        Self.logger.info("Socket reconnecting in \(delay, privacy: .public)")
        reconnectTask = Task { [weak self] in
            do { try await clock.sleep(for: delay) } catch { return }
            await self?.reconnectFired(id: id)
        }
    }

    private func reconnectFired(id: Int) async {
        guard id == reconnectID, mode == .active else { return }
        reconnectTask = nil
        await open()
    }

    private func cancelReconnect() {
        reconnectID += 1
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    /// Starts or restarts a deadline.
    private func startDeadline(_ deadline: Deadline, after timeout: Duration) {
        deadlines[deadline]?.task.cancel()
        nextDeadlineID += 1
        let id = nextDeadlineID
        let clock = clock
        let task = Task { [weak self] in
            do { try await clock.sleep(for: timeout) } catch { return }
            await self?.deadlinePassed(deadline, id: id)
        }
        deadlines[deadline] = (id, task)
    }

    private func cancelDeadline(_ deadline: Deadline) {
        deadlines.removeValue(forKey: deadline)?.task.cancel()
    }

    private func deadlinePassed(_ deadline: Deadline, id: Int) {
        guard deadlines[deadline]?.id == id else { return }
        deadlines[deadline] = nil
        switch deadline {
        case .connect:
            Self.logger.notice("Socket namespace connection timed out")
            _ = closeConnection()
        case .liveness:
            Self.logger.notice("Socket heartbeat timed out")
            tearDown(reason: .pingTimeout)
        }
        scheduleReconnect()
    }

    // MARK: - Packets

    private func receive(_ message: WebSocketMessage, generation: Int) async {
        guard generation == self.generation else { return }
        guard case .text(let text) = message else {
            Self.logger.debug("Ignoring binary socket frame")
            return
        }
        let packet: EngineIOPacket
        do {
            packet = try EngineIOPacket(decoding: text)
        } catch {
            Self.logger.error("Dropping undecodable Engine.IO packet: \(String(describing: error), privacy: .public)")
            return
        }
        switch packet {
        case .open(let handshake):
            livenessTimeout = handshake.livenessTimeout
            startDeadline(.liveness, after: handshake.livenessTimeout)
            await send(Self.wrap(.connect()), generation: generation)
        case .ping(let data):
            if let livenessTimeout { startDeadline(.liveness, after: livenessTimeout) }
            await send(EngineIOPacket.pong(data).encoded, generation: generation)
        case .close:
            tearDown(reason: .serverClosed)
            scheduleReconnect()
        case .message(let text):
            await receiveSocketIO(text, generation: generation)
        case .pong, .upgrade, .noop:
            break
        }
    }

    private func receiveSocketIO(_ text: String, generation: Int) async {
        let packet: SocketIOPacket
        do {
            packet = try SocketIOPacket(decoding: text)
        } catch {
            Self.logger.error("Dropping undecodable Socket.IO packet: \(String(describing: error), privacy: .public)")
            return
        }
        switch packet {
        case .connect(SocketIOPacket.mainNamespace, _):
            cancelDeadline(.connect)
            isConnected = true
            attempt = 0
            continuation.yield(.connected)
            await sendAuth(generation: generation)
        case .connectError(SocketIOPacket.mainNamespace, let message):
            Self.logger.error("Socket connect error: \(message ?? "unknown", privacy: .public)")
            _ = closeConnection()
            continuation.yield(.disconnected(.connectError(message: message)))
            scheduleReconnect()
        case .disconnect(SocketIOPacket.mainNamespace):
            tearDown(reason: .serverClosed)
            scheduleReconnect()
        case .event(SocketIOPacket.mainNamespace, _, let name, let arguments):
            receiveEvent(name: name, arguments: arguments)
        default:
            break
        }
    }

    private func receiveEvent(name: String, arguments: Data) {
        let event: RealtimeEvent?
        do {
            event = try RealtimeEvent.decode(name: name, arguments: arguments)
        } catch {
            Self.logger.error(
                "Dropping malformed \(name, privacy: .public) event: \(String(describing: error), privacy: .public)"
            )
            return
        }
        guard let event else { return }
        continuation.yield(event)
        if case .authFailed(let message) = event {
            Self.logger.error("Socket auth failed: \(message ?? "unknown", privacy: .public)")
            mode = .haltedByAuthFailure
            cancelReconnect()
            tearDown(reason: .authFailed)
        }
    }

    private func sendAuth(generation: Int) async {
        guard let token else { return }
        do {
            await send(Self.wrap(try .event("auth", token)), generation: generation)
        } catch {
            Self.logger.error("Could not encode auth event: \(String(describing: error), privacy: .public)")
        }
    }

    private func send(_ text: String, generation: Int) async {
        guard generation == self.generation, let connection else { return }
        do {
            try await connection.send(text)
        } catch {
            // Receiving may carry on after a failed send, so don't wait for it to fail. The
            // generation check keeps a late failure from closing a replacement connection.
            guard generation == self.generation else { return }
            Self.logger.info("Socket send failed: \(error.localizedDescription, privacy: .public)")
            tearDown(reason: .transportClosed)
            scheduleReconnect()
        }
    }

    private static func wrap(_ packet: SocketIOPacket) -> String {
        EngineIOPacket.message(packet.encoded).encoded
    }
}
