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
    /// Before the open packet arrives there's no `pingInterval`; socket.io-client's default
    /// connect timeout applies.
    static let handshakeTimeout: Duration = .seconds(20)

    private enum Mode {
        case idle
        case active
        case haltedByAuthFailure
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
    private var watchdogTask: Task<Void, Never>?
    private var watchdogID = 0
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
        watchdogTask?.cancel()
        reconnectTask?.cancel()
        connection?.close()
        continuation.finish()
    }

    /// Connects, or reconnects immediately if already connected. Resets the backoff and resumes
    /// after an `auth_failed`.
    public func connect() async {
        mode = .active
        await reconnectNow(reason: .clientRequested)
    }

    /// Closes the socket and stops reconnecting.
    public func disconnect() async {
        mode = .idle
        cancelReconnect()
        if isConnected, let connection {
            try? await connection.send(Self.wrap(.disconnect()))
        }
        tearDown(reason: .clientRequested)
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
        restartWatchdog(Self.handshakeTimeout)
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

    /// Closes the current connection without scheduling a reconnect.
    private func tearDown(reason: RealtimeDisconnectReason) {
        generation += 1
        watchdogID += 1
        receiveTask?.cancel()
        receiveTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        connection?.close()
        connection = nil
        livenessTimeout = nil
        if isConnected {
            isConnected = false
            continuation.yield(.disconnected(reason))
        }
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

    private func restartWatchdog(_ timeout: Duration) {
        watchdogTask?.cancel()
        watchdogID += 1
        let id = watchdogID
        let clock = clock
        watchdogTask = Task { [weak self] in
            do { try await clock.sleep(for: timeout) } catch { return }
            await self?.watchdogFired(id: id)
        }
    }

    private func watchdogFired(id: Int) {
        guard id == watchdogID, connection != nil else { return }
        Self.logger.notice("Socket heartbeat timed out")
        tearDown(reason: .pingTimeout)
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
        if case .open(let handshake) = packet {
            livenessTimeout = handshake.livenessTimeout
        }
        restartWatchdog(livenessTimeout ?? Self.handshakeTimeout)

        switch packet {
        case .open:
            await send(Self.wrap(.connect()), generation: generation)
        case .ping(let data):
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
            isConnected = true
            attempt = 0
            continuation.yield(.connected)
            await sendAuth(generation: generation)
        case .connectError(SocketIOPacket.mainNamespace, let message):
            Self.logger.error("Socket connect error: \(message ?? "unknown", privacy: .public)")
            tearDown(reason: .connectError(message: message))
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
        guard let token else {
            Self.logger.error("Socket connected without a token; not authenticating")
            return
        }
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
            // The receive loop sees the same failure and reconnects.
            Self.logger.info("Socket send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func wrap(_ packet: SocketIOPacket) -> String {
        EngineIOPacket.message(packet.encoded).encoded
    }
}
