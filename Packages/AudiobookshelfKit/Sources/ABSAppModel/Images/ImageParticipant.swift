import ABSAPI
import ABSCore
import Foundation
import Observation

/// Where ``ImageParticipant`` installs each connection's request builder; ``ImagePipeline`` in
/// the app, a fake in tests.
public protocol ImageRequestBuilderSink: Sendable {
    /// Sets or, with `nil`, removes the request builder for one server connection.
    func setRequestBuilder(_ builder: (any ImageRequestBuilding)?, for serverID: UUID) async
    /// Forgets a removed server and its cached covers.
    func removeServer(_ serverID: UUID) async
    /// A sweep's first step: forgets what is loaded for servers not in `saved` and not given a
    /// builder since launch, and returns the servers with cached covers not in `saved`.
    func serversToSweep(keepingOnly saved: Set<UUID>) async -> Set<UUID>
    /// Forgets a swept server and its cached covers, as ``removeServer(_:)`` does, unless it has
    /// been given a builder since launch. Returns whether it was removed.
    @discardableResult
    func removeServerUnlessInSession(_ serverID: UUID) async -> Bool
}

extension ImagePipeline: ImageRequestBuilderSink {}

/// Gives the image pipeline the session's ``MediaURLBuilder`` (ADR 0005).
///
/// A ``SessionStage/connect`` participant:
/// - On start and reconnect it installs a builder from the session client's configuration, so
///   covers follow the connection's address and custom headers. A new sign-in brings a new client,
///   and so a reconnect.
/// - On end, whatever the reason, it removes the builder; cached covers stay on disk for the next
///   sign-in. Only ``remove(_:)`` deletes a server's covers, once the server is removed
///   (``followRemovals(of:)``).
///
/// The pipeline keys every builder by connection, so only calls for the same connection need an
/// order: each connection's calls run one at a time, in call order. A builder still being
/// installed when the session ends (or an end the lifecycle stopped waiting for) therefore lands
/// before that end's removal, or before the builder of the connection's next session; and no
/// connection waits for another's, such as a removed server's cover deletion.
@MainActor
public final class ImageParticipant: SessionParticipant {
    private let sink: any ImageRequestBuilderSink

    /// Bumped on start and end, so an install queued for an earlier session does nothing.
    private var generation = 0
    /// The running session's connection; `nil` when none runs.
    private var connectionID: UUID?
    private var client: APIClient?
    private var removals: Task<Void, Never>?
    /// Whether ``sweepRemovedConnections(savedConnections:)`` has run.
    private var sweptRemovedConnections = false
    /// The latest pipeline call of each connection; the connection's next call waits for it.
    private var tails: [UUID: (call: Int, task: Task<Void, Never>)] = [:]
    private var nextCall = 0

    // TODO(#40): Editing a saved server's custom headers needs a per-connection header revision
    // to observe here, and a rebuild when it changes. Nothing edits them today: they're saved with
    // each sign-in, whose new client reaches `sessionDidReconnect(_:)` or a new session.
    public init(sink: any ImageRequestBuilderSink) {
        self.sink = sink
    }

    isolated deinit {
        removals?.cancel()
    }

    // MARK: - SessionParticipant

    public func sessionDidStart(_ context: SessionContext) async {
        generation += 1
        connectionID = context.identity.connectionID
        client = context.client
        await install(for: context.identity.connectionID).value
    }

    /// Rebuilds the builder from the new client.
    public func sessionDidReconnect(_ context: SessionContext) async {
        guard connectionID == context.identity.connectionID else { return }
        client = context.client
        await install(for: context.identity.connectionID).value
    }

    /// Ends the session before the first `await`, then removes the builder. Never deletes covers.
    public func sessionWillEnd(_ reason: SessionEndReason) async {
        generation += 1
        client = nil
        guard let connectionID else { return }
        self.connectionID = nil
        let sink = self.sink
        await enqueue(for: connectionID) { await sink.setRequestBuilder(nil, for: connectionID) }.value
    }

    // MARK: - Removal

    /// Forgets a removed server's builder and cached covers.
    public func remove(_ connectionID: UUID) async {
        let sink = self.sink
        await enqueue(for: connectionID) { await sink.removeServer(connectionID) }.value
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

    /// Deletes, once per launch, the covers of connections removed in an earlier launch: a
    /// removal the app was terminated in after the store removed the connection, but before
    /// ``remove(_:)`` ran, left them with no connection to follow (#421).
    ///
    /// Each server's removal runs in its connection's queue, like ``remove(_:)``: a session
    /// started for it first keeps its covers, and one started meanwhile installs its builder only
    /// once the removal (its lease wait included) is done, so it can't cache covers the removal
    /// then deletes.
    ///
    /// - Parameter savedConnections: The saved connections read from the store, or `nil` if it
    ///   can't be read, which skips the sweep (`AccountManager.savedConnectionIDs()`). Never a
    ///   list that may not have loaded yet, which would delete every connection's covers.
    public func sweepRemovedConnections(savedConnections: @MainActor () async -> Set<UUID>?) async {
        guard !sweptRemovedConnections, let saved = await savedConnections() else { return }
        sweptRemovedConnections = true
        let sink = self.sink
        let removals = await sink.serversToSweep(keepingOnly: saved).map { serverID in
            enqueue(for: serverID) { await sink.removeServerUnlessInSession(serverID) }
        }
        for removal in removals { await removal.value }
    }

    // MARK: - Builder

    /// Installs a builder from the latest client, unless the session has ended by its turn.
    private func install(for connectionID: UUID) -> Task<Void, Never> {
        let generation = generation
        let sink = self.sink
        return enqueue(for: connectionID) { [weak self] in
            guard let self, generation == self.generation else { return }
            // Offline without a client, the pipeline only serves cached covers.
            var builder: MediaURLBuilder?
            if let client = self.client {
                builder = MediaURLBuilder(configuration: await client.configuration)
            }
            guard generation == self.generation else { return }
            await sink.setRequestBuilder(builder, for: connectionID)
        }
    }

    private func enqueue(
        for connectionID: UUID, _ body: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let previous = tails[connectionID]?.task
        nextCall += 1
        let call = nextCall
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await body()
            // Nothing queued behind it: the connection's chain is empty again.
            if self?.tails[connectionID]?.call == call { self?.tails[connectionID] = nil }
        }
        tails[connectionID] = (call, task)
        return task
    }
}
