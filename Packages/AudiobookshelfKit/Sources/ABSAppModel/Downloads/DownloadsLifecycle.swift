import ABSCore
import ABSData
import ABSDownloads
import Foundation
import Synchronization

/// What ``DownloadsLifecycle`` needs from ``DownloadEngine``, so it can be tested with a fake.
/// ``DownloadEngine`` conforms; see it for what each member means.
public protocol DownloadsLifecycleEngine: Sendable {
    /// See ``DownloadEngine/activate()``.
    func activate() async -> Bool
    /// See ``DownloadEngine/deactivate()``.
    func deactivate() async
    /// See ``DownloadEngine/quiesce(connectionID:pausing:)``.
    func quiesce(connectionID: UUID, pausing: @Sendable () async -> Void) async -> Bool
}

extension DownloadEngine: DownloadsLifecycleEngine {}

/// What ``DownloadsLifecycle`` needs from ``DownloadManager``, so it can be tested with a fake.
/// ``DownloadManager`` conforms; see it for what each member means.
public protocol DownloadsLifecycleManager: Sendable {
    /// See ``DownloadManager/start()``.
    func start() async throws
    /// See ``DownloadManager/pause(recordID:)``.
    func pause(recordID: UUID) async throws(DownloadManagerError) -> Bool
}

extension DownloadManager: DownloadsLifecycleManager {}

/// Drives the download stack through the app's life: launch, scene phases, and the end of an
/// account's session.
///
/// - ``launch()`` starts the manager (before the engine's first activation, as
///   ``DownloadManager/start()`` asks), which prepares the download folders. It neither
///   activates the engine nor starts the controller (whose network policy can restart
///   transfers), so a launch without a window (CarPlay, a background wake) starts no transfer.
/// - ``handle(scenePhase:)`` runs the phases one after another, in call order. Each
///   ``SessionScenePhase/active`` launches if needed, prepares the folders again if that failed,
///   and only once they are prepared starts the controller (once) and activates the engine.
///   If that succeeded, it then retries unfinished cleanups and sweeps what downloads left
///   behind (``DownloadJanitor``), outside the chain, so neither holds up the next phase.
///   ``SessionScenePhase/background`` deactivates the engine, after any activation called
///   before it, so the app never stays activated in the background.
/// - As a ``SessionParticipant``, a sign-out or expiry of the session's connection pauses that
///   connection's queued and downloading records, within a quiesce of it
///   (``DownloadEngine/quiesce(connectionID:pausing:)``): every transfer stops and its resume
///   data is discarded (ADR 0003), since resume data is sealed to the credentials it was made
///   with and couldn't be used after signing in again. The records stay paused after signing in
///   again; the user resumes them. This is local only, so it is also safe for an expiry. A switch
///   keeps them running: the other connection's credentials stay saved. A removal does the same
///   as a sign-out, but in ``connectionRemoved(_:)``, once the credentials are deleted. An
///   expiry does the same in ``connectionExpired(_:)``, whatever the session's end says (a
///   switch can be under way, or there may be no session of it, during a restore).
/// - A cleanup runs in its own task, so it outlives the session teardown's time budget; a new
///   session of the same connection waits for it in ``sessionDidStart(_:)``, so it can't pause
///   or discard what that session starts. A cleanup that couldn't stop the transfers (the engine
///   had no session) or save a record's pause still deletes the resume data it can, and is tried again after the next
///   successful activation, unless a session of the connection starts first; either way the
///   engine cancels the connection's transfers that survived a relaunch once it has a session.
/// - These waits (a new session's, and a removal's in ``connectionRemoved(_:)``, which
///   ``AccountManager/remove(_:)`` awaits) have no time limit, so a later sign-in or removal can
///   never overlap a cleanup; one longer than ``slowCleanup`` is logged. The trade-off: if a step
///   of the cleanup (a store write, a transfer's cancellation) never returned, they would wait
///   for good.
@MainActor
public final class DownloadsLifecycle: SessionParticipant {
    private let engine: any DownloadsLifecycleEngine
    private let manager: any DownloadsLifecycleManager
    private let records: @Sendable (UUID) async throws -> [DownloadRecordDTO]
    private let startController: @MainActor () async -> Void
    private let sweep: @Sendable () async -> Void

    private var launching: Task<Void, Never>?
    /// Whether the manager has prepared the download folders. Until then nothing starts a
    /// transfer: the engine isn't activated and the controller (whose network policy restarts
    /// transfers) isn't started. The next active phase tries again.
    private var isPrepared = false
    private var controllerStarted = false
    /// The last phase handled; the next one waits for it. Its value is whether it activated.
    private var lastPhase: Task<Bool, Never>?
    /// The connection of the running session.
    private var connectionID: UUID?
    /// Each connection's last cleanup; the next one, and a new session of it, waits for it.
    private var cleanups: [UUID: Task<Void, Never>] = [:]
    /// Connections whose cleanup couldn't stop their transfers; tried again after activating.
    private var unfinishedCleanups: Set<UUID> = []

    /// - Parameters:
    ///   - engine: the app's ``DownloadEngine``.
    ///   - manager: the app's ``DownloadManager``.
    ///   - records: a connection's download records, for example
    ///     `DownloadStore.records(serverConnectionID:)`.
    ///   - startController: starts the ``DownloadsController``.
    ///   - sweep: runs the ``DownloadJanitor``.
    public init(
        engine: any DownloadsLifecycleEngine,
        manager: any DownloadsLifecycleManager,
        records: @escaping @Sendable (UUID) async throws -> [DownloadRecordDTO],
        startController: @escaping @MainActor () async -> Void,
        sweep: @escaping @Sendable () async -> Void
    ) {
        self.engine = engine
        self.manager = manager
        self.records = records
        self.startController = startController
        self.sweep = sweep
    }

    // MARK: - App lifecycle

    /// Starts the manager. Only the first call does anything; every call returns that work.
    @discardableResult
    public func launch() -> Task<Void, Never> {
        if let launching { return launching }
        let launching = Task { _ = await self.prepare() }
        self.launching = launching
        return launching
    }

    /// Handles a scene phase after the ones handled before it (see ``DownloadsLifecycle``).
    ///
    /// - Returns: the phase's work, including the sweep after an activation.
    @discardableResult
    public func handle(scenePhase: SessionScenePhase) -> Task<Void, Never> {
        let previous = lastPhase
        let phase = Task { () -> Bool in
            _ = await previous?.value
            return await self.run(scenePhase)
        }
        lastPhase = phase
        return Task { [sweep] in
            // Outside the chain, so a background phase deactivates without waiting for a retry or
            // the sweep, which only follow an activation that succeeded.
            guard await phase.value else { return }
            // Each after its connection's previous cleanup but alongside the others', so a stuck one
            // doesn't hold up theirs; the sweep waits for them all.
            let retries = self.unfinishedCleanups.map { self.startCleanup(of: $0) }
            for retry in retries { await Self.wait(for: retry) }
            await sweep()
        }
    }

    private func run(_ phase: SessionScenePhase) async -> Bool {
        switch phase {
        case .active:
            await launch().value
            guard await prepare() else { return false }
            if !controllerStarted {
                controllerStarted = true
                await startController()
            }
            return await engine.activate()
        case .background:
            await engine.deactivate()
            return false
        case .inactive:
            return false
        }
    }

    /// Starts the manager until it has prepared the folders.
    ///
    /// - Returns: whether the folders are prepared.
    private func prepare() async -> Bool {
        guard !isPrepared else { return true }
        do {
            try await manager.start()
            isPrepared = true
            return true
        } catch {
            Log.downloads.error(
                "Couldn't prepare the download folders: \(Log.redact(String(describing: error)), privacy: .public)")
            return false
        }
    }

    // MARK: - Connections

    /// Pauses a removed connection's queued and downloading records, then quiesces it. Call it
    /// once the connection's credentials are deleted (``AccountManager/credentialsRemoved``) and
    /// before the store removes it, whether or not its session is running: a removal that fails
    /// earlier keeps the downloads and their progress.
    public func connectionRemoved(_ connectionID: UUID) async {
        await stopDownloads(of: connectionID)
    }

    /// Pauses an expired connection's queued and downloading records, then quiesces it, after
    /// its previous cleanup, for every expiry: its running session may end with a switch
    /// already under way, or there may be none (a restore, another connection). A session of
    /// it that starts later waits for this. Call it once the connection's tokens are deleted
    /// (``AccountManager/credentialsExpired``).
    public func connectionExpired(_ connectionID: UUID) {
        _ = startCleanup(of: connectionID)
    }

    public func sessionDidStart(_ context: SessionContext) async {
        let id = context.identity.connectionID
        connectionID = id
        // A cleanup that outlived the last teardown's budget pauses and discards only what the
        // ended session left; then it isn't tried again over this session's downloads.
        while let pending = cleanups[id] {
            await Self.wait(for: pending)
            // Done unless a retry after an activation began meanwhile.
            if cleanups[id] == pending { break }
        }
        unfinishedCleanups.remove(id)
    }

    public func sessionWillEnd(_ reason: SessionEndReason) async {
        let ended = connectionID
        connectionID = nil
        // A removal stops the downloads once the credentials are deleted (connectionRemoved).
        guard let ended, reason == .signOut || reason == .expired else { return }
        await stopDownloads(of: ended)
    }

    /// In its own task, after the connection's previous cleanup, so the session teardown's time
    /// budget, which cancels the waiting call, can't skip the quiesce after the pause.
    private func stopDownloads(of connectionID: UUID) async {
        await Self.wait(for: startCleanup(of: connectionID))
    }

    /// Starts the cleanup of `connectionID` after its previous one, registered before this
    /// returns, so a session of it that starts later waits for it.
    private func startCleanup(of connectionID: UUID) -> Task<Void, Never> {
        let records = records
        let manager = manager
        let engine = engine
        let previous = cleanups[connectionID]
        let cleanup = Task {
            await previous?.value
            // Paused within the quiesce, so a failure's replay can't queue a record again after
            // the read; pausing seals resume data with the old credentials, so it's discarded after.
            // A pause that isn't saved leaves a record the next activation would restart. One a
            // policy restart has paused for now is skipped, but its resume is refused once this began.
            let paused = Mutex(true)
            let quiesced = await engine.quiesce(connectionID: connectionID) {
                do {
                    for record in try await records(connectionID)
                    where [.queued, .downloading].contains(record.state) {
                        do {
                            _ = try await manager.pause(recordID: record.id)
                        } catch {
                            paused.withLock { $0 = false }
                            Log.downloads.error(
                                "Couldn't pause a download of a signed-out server: \(String(describing: error), privacy: .public)"
                            )
                        }
                    }
                } catch {
                    paused.withLock { $0 = false }
                    Log.downloads.error(
                        "Couldn't read the downloads of a signed-out server: \(Log.redact(String(describing: error)), privacy: .public)"
                    )
                }
            }
            if quiesced, paused.withLock({ $0 }) {
                self.unfinishedCleanups.remove(connectionID)
            } else {
                Log.downloads.error("Couldn't stop a signed-out server's downloads; will retry")
                self.unfinishedCleanups.insert(connectionID)
            }
        }
        cleanups[connectionID] = cleanup
        Task {
            await cleanup.value
            if self.cleanups[connectionID] == cleanup { self.cleanups[connectionID] = nil }
        }
        return cleanup
    }

    /// How long a wait for a cleanup lasts before it's logged.
    static let slowCleanup: Duration = .seconds(5)

    /// Waits for `cleanup` without a time limit (see ``DownloadsLifecycle``), logging once if it
    /// takes longer than ``slowCleanup``.
    private static func wait(for cleanup: Task<Void, Never>) async {
        let warning = Task {
            try await Task.sleep(for: slowCleanup)
            Log.downloads.warning("Still waiting for a signed-out server's downloads to stop")
        }
        await cleanup.value
        warning.cancel()
    }
}
