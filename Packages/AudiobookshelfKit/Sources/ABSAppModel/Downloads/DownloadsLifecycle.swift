import ABSCore
import ABSData
import ABSDownloads
import Foundation

/// What ``DownloadsLifecycle`` needs from ``DownloadEngine``, so it can be tested with a fake.
/// ``DownloadEngine`` conforms; see it for what each member means.
public protocol DownloadsLifecycleEngine: Sendable {
    /// See ``DownloadEngine/activate()``.
    func activate() async -> Bool
    /// See ``DownloadEngine/deactivate()``.
    func deactivate() async
    /// See ``DownloadEngine/quiesce(connectionID:)``.
    func quiesce(connectionID: UUID) async -> Bool
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
///   ``DownloadManager/start()`` asks) and then, once the download folders are prepared, the
///   controller, once. It doesn't activate the engine, so a launch without a window (CarPlay, a
///   background wake) restarts nothing.
/// - ``handle(scenePhase:)`` runs the phases one after another, in call order. Each
///   ``SessionScenePhase/active`` launches if needed, prepares the folders again if that failed
///   (starting the controller once they are), then activates the engine only if the folders are
///   prepared, then, if that succeeded, sweeps what downloads left behind (``DownloadJanitor``) without holding up
///   the next phase. ``SessionScenePhase/background`` deactivates the engine, after any
///   activation called before it, so the app never stays activated in the background.
/// - As a ``SessionParticipant``, a sign-out or expiry of the session's connection pauses that
///   connection's queued and downloading records, then quiesces it
///   (``DownloadEngine/quiesce(connectionID:)``): every transfer stops and its resume data is
///   discarded (ADR 0003), since resume data is sealed to the credentials it was made with and
///   couldn't be used after signing in again. The records stay paused after signing in again;
///   the user resumes them. This is local only, so it is also safe for an expiry. A switch keeps
///   them running: the other connection's credentials stay saved. A removal does the same as a
///   sign-out, but in ``connectionRemoved(_:)``, once the credentials are deleted.
/// - A cleanup runs in its own task, so it outlives the session teardown's time budget; a new
///   session of the same connection waits for it in ``sessionDidStart(_:)``, so it can't pause
///   or discard what that session starts. A cleanup that couldn't stop the transfers (the engine
///   had no session) is tried again after the next successful activation, unless a session of
///   the connection starts first.
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
    /// transfers) isn't started. The next activation tries again.
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

    /// Starts the manager, then the controller. Only the first call does anything; every call
    /// returns that work.
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
            // Outside the chain, so a background phase deactivates without waiting for the sweep,
            // which only follows an activation that succeeded.
            if await phase.value { await sweep() }
        }
    }

    private func run(_ phase: SessionScenePhase) async -> Bool {
        switch phase {
        case .active:
            await launch().value
            guard await prepare() else { return false }
            guard await engine.activate() else { return false }
            // Checked again for each, in case a session of it started meanwhile.
            for id in unfinishedCleanups where unfinishedCleanups.contains(id) { await stopDownloads(of: id) }
            return true
        case .background:
            await engine.deactivate()
            return false
        case .inactive:
            return false
        }
    }

    /// Starts the manager until it has prepared the folders, then the controller once.
    ///
    /// - Returns: whether the folders are prepared.
    private func prepare() async -> Bool {
        if !isPrepared {
            do {
                try await manager.start()
                isPrepared = true
            } catch {
                Log.downloads.error(
                    "Couldn't prepare the download folders: \(Log.redact(String(describing: error)), privacy: .public)")
                return false
            }
        }
        if !controllerStarted {
            controllerStarted = true
            await startController()
        }
        return true
    }

    // MARK: - Connections

    /// Pauses a removed connection's queued and downloading records, then quiesces it. Call it
    /// once the connection's credentials are deleted (``AccountManager/credentialsRemoved``) and
    /// before the store removes it, whether or not its session is running: a removal that fails
    /// earlier keeps the downloads and their progress.
    public func connectionRemoved(_ connectionID: UUID) async {
        await stopDownloads(of: connectionID)
    }

    public func sessionDidStart(_ context: SessionContext) async {
        let id = context.identity.connectionID
        connectionID = id
        // A cleanup that outlived the last teardown's budget pauses and discards only what the
        // ended session left; then it isn't tried again over this session's downloads.
        while let pending = cleanups[id] {
            await pending.value
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
        let records = records
        let manager = manager
        let engine = engine
        let previous = cleanups[connectionID]
        let cleanup = Task {
            await previous?.value
            do {
                for record in try await records(connectionID) where [.queued, .downloading].contains(record.state) {
                    do {
                        _ = try await manager.pause(recordID: record.id)
                    } catch {
                        Log.downloads.error(
                            "Couldn't pause a download of a signed-out server: \(String(describing: error), privacy: .public)"
                        )
                    }
                }
            } catch {
                Log.downloads.error(
                    "Couldn't read the downloads of a signed-out server: \(Log.redact(String(describing: error)), privacy: .public)"
                )
            }
            // Pausing seals resume data with the old credentials, so it's discarded after.
            if await engine.quiesce(connectionID: connectionID) {
                self.unfinishedCleanups.remove(connectionID)
            } else {
                Log.downloads.error("Couldn't stop a signed-out server's downloads; will retry")
                self.unfinishedCleanups.insert(connectionID)
            }
        }
        cleanups[connectionID] = cleanup
        await cleanup.value
        if cleanups[connectionID] == cleanup { cleanups[connectionID] = nil }
    }
}
