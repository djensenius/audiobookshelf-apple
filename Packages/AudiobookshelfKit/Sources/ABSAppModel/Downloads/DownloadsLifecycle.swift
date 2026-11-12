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
    /// See ``DownloadEngine/discardResumeData(connectionID:)``.
    func discardResumeData(connectionID: UUID) async
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
/// - As a ``SessionParticipant``, a sign-out, expiry or removal of the session's connection
///   pauses that connection's queued and downloading records, then discards its resume data
///   (ADR 0003): resume data is sealed to the credentials it was made with, so it couldn't be
///   used after signing in again. The records stay paused after signing in again; the user
///   resumes them. This is local only, so it is also safe for an expiry. A switch keeps them
///   running: the other connection's credentials stay saved.
/// - ``connectionRemoved(_:)`` does the same for a connection removed while it isn't active.
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
            return await engine.activate()
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

    /// Pauses a removed connection's queued and downloading records, then discards its resume
    /// data. For a removal of a connection whose session isn't running; the active one's ends
    /// with ``SessionEndReason/removed``, which does the same.
    public func connectionRemoved(_ connectionID: UUID) async {
        await stopDownloads(of: connectionID)
    }

    public func sessionDidStart(_ context: SessionContext) async {
        connectionID = context.identity.connectionID
    }

    public func sessionWillEnd(_ reason: SessionEndReason) async {
        let ended = connectionID
        connectionID = nil
        guard let ended, reason != .switch else { return }
        await stopDownloads(of: ended)
    }

    /// In its own task, so the session teardown's time budget, which cancels the waiting call,
    /// can't skip the discard after the pause.
    private func stopDownloads(of connectionID: UUID) async {
        let records = records
        let manager = manager
        let engine = engine
        await Task {
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
            await engine.discardResumeData(connectionID: connectionID)
        }.value
    }
}
