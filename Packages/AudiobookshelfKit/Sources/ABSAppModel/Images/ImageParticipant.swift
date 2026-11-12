import ABSAPI
import ABSCore
import ABSData
import Foundation
import Observation

/// Where ``ImageParticipant`` installs each connection's request builder; ``ImagePipeline`` in
/// the app, a fake in tests.
public protocol ImageRequestBuilderSink: Sendable {
    /// Sets or, with `nil`, removes the request builder for one server connection.
    func setRequestBuilder(_ builder: (any ImageRequestBuilding)?, for serverID: UUID) async
    /// Forgets a removed server and its cached covers.
    func removeServer(_ serverID: UUID) async
}

extension ImagePipeline: ImageRequestBuilderSink {}

/// Gives the image pipeline the session's ``MediaURLBuilder`` (ADR 0005).
///
/// A ``SessionStage/connect`` participant:
/// - On start and reconnect it installs a builder from the session client's configuration, so
///   covers follow the connection's address and custom headers.
/// - While the session runs it watches the active connection and rebuilds the builder when that
///   connection changes, say after its custom headers were edited. The watch ends with the
///   session.
/// - On end, whatever the reason, it removes the builder; cached covers stay on disk for the next
///   sign-in. Only ``remove(_:)`` deletes a server's covers, once the server is removed
///   (``followRemovals(of:)``).
///
/// Every change to the pipeline runs in call order, so a rebuild still in flight when the session
/// ends can't install its builder after the end removed it.
@MainActor
public final class ImageParticipant: SessionParticipant {
    private let sink: any ImageRequestBuilderSink
    private let activeConnection: @MainActor @Sendable () -> ServerConnectionDTO?

    /// Bumped on start and end, so work of an earlier session does nothing.
    private var generation = 0
    /// The running session's connection; `nil` when none runs.
    private var connectionID: UUID?
    private var client: APIClient?
    /// The active-connection watch; cancelled on end.
    private(set) var observation: Task<Void, Never>?
    private var removals: Task<Void, Never>?
    /// The latest change to the pipeline; the next one waits for it.
    private var tail: Task<Void, Never>?

    /// - Parameters:
    ///   - sink: The image pipeline.
    ///   - activeConnection: The account's active connection (`AccountManager.activeConnection`),
    ///     read with Observation: a change to the session's connection rebuilds the builder.
    public init(
        sink: any ImageRequestBuilderSink,
        activeConnection: @escaping @MainActor @Sendable () -> ServerConnectionDTO? = { nil }
    ) {
        self.sink = sink
        self.activeConnection = activeConnection
    }

    isolated deinit {
        observation?.cancel()
        removals?.cancel()
    }

    // MARK: - SessionParticipant

    public func sessionDidStart(_ context: SessionContext) async {
        generation += 1
        connectionID = context.identity.connectionID
        client = context.client
        observeActiveConnection()
        await install().value
    }

    /// Rebuilds the builder from the new client.
    public func sessionDidReconnect(_ context: SessionContext) async {
        guard connectionID == context.identity.connectionID else { return }
        client = context.client
        await install().value
    }

    /// Stops the watch before the first `await`, then removes the builder. Never deletes covers.
    public func sessionWillEnd(_ reason: SessionEndReason) async {
        generation += 1
        observation?.cancel()
        observation = nil
        client = nil
        guard let connectionID else { return }
        self.connectionID = nil
        let sink = self.sink
        await enqueue { await sink.setRequestBuilder(nil, for: connectionID) }.value
    }

    // MARK: - Removal

    /// Forgets a removed server's builder and cached covers.
    public func remove(_ connectionID: UUID) async {
        let sink = self.sink
        await enqueue { await sink.removeServer(connectionID) }.value
    }

    /// Calls ``remove(_:)`` for every connection that leaves `savedConnections`, read with
    /// Observation (`AccountManager.connections`, which lists neither removed connections nor
    /// any whose removal failed). Signing out keeps a connection listed, so it keeps its covers.
    /// Follows until the participant is released or this is called again.
    public func followRemovals(of savedConnections: @escaping @MainActor @Sendable () -> Set<UUID>) {
        removals?.cancel()
        let initial = savedConnections()
        removals = Task { [weak self] in
            var known = initial
            for await saved in Observations({ @MainActor in savedConnections() }) {
                guard !Task.isCancelled else { return }
                for removed in known.subtracting(saved) {
                    guard let self else { return }
                    await self.remove(removed)
                }
                known = saved
            }
        }
    }

    // MARK: - Builder

    /// Installs a builder from the latest client, unless the session has ended by its turn.
    @discardableResult
    private func install() -> Task<Void, Never> {
        let generation = generation
        let sink = self.sink
        return enqueue { [weak self] in
            guard let self, generation == self.generation, let connectionID = self.connectionID else { return }
            // Offline without a client, the pipeline only serves cached covers.
            var builder: MediaURLBuilder?
            if let client = self.client {
                builder = MediaURLBuilder(configuration: await client.configuration)
            }
            guard generation == self.generation else { return }
            await sink.setRequestBuilder(builder, for: connectionID)
        }
    }

    private func observeActiveConnection() {
        observation?.cancel()
        let generation = generation
        let activeConnection = self.activeConnection
        let initial = activeConnection()
        observation = Task { [weak self] in
            var seen = initial
            for await connection in Observations({ @MainActor in activeConnection() }) {
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                guard connection != seen else { continue }
                seen = connection
                guard connection?.id == self.connectionID else { continue }
                self.install()
            }
        }
    }

    private func enqueue(_ body: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await body()
        }
        tail = task
        return task
    }
}
