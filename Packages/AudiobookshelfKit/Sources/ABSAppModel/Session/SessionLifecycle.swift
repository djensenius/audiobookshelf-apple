import ABSAPI
import Foundation
import Observation

/// A scene phase, so ``SessionLifecycle`` doesn't import SwiftUI. The app maps
/// `ScenePhase` onto it.
public enum SessionScenePhase: Sendable, Hashable {
    case active
    case inactive
    case background
}

/// Starts and ends the per-account session, in an order that keeps the library's progress seed
/// correct, and decides the ``AuthGate``.
///
/// One instance is shared by every window scene and CarPlay. Each part of the app with
/// per-account state registers as a ``SessionParticipant`` before ``start()``.
///
/// **Start order.** A session runs one fixed pipeline:
/// 1. ``SessionStage/connect`` participants, in registration order, with the
///    ``SessionSeeding`` seeder always first (the library connects).
/// 2. ``SessionSeeding/beginSeed(_:)``.
/// 3. ``SessionStage/progressSource`` participants, in registration order.
/// 4. ``SessionSeeding/seed(_:)`` (fetch `/api/me`, then seed), in its own task.
///
/// A participant's ``SessionStage`` is the only way into the pipeline, so anything that applies
/// progress is registered as ``SessionStage/progressSource`` and can't start before the seed
/// boundary: progress it applies is never dropped by the seed.
///
/// **End order.** The started participants end in reverse start order, so the progress sources
/// stop before the library clears, and only then does the account sign out or switch. A switch
/// from A to B ends A completely before B's pipeline starts. Before a sign-out or switch, every
/// participant is flushed, waiting at most `flushTimeout`. When the account's identity
/// disappears without ``signOut()`` or ``switchAccount(to:)`` (the server rejected the session),
/// the same teardown runs with ``SessionEndReason/expired`` and without a flush.
///
/// Every transition runs one at a time on the main actor, in call order.
@MainActor @Observable
public final class SessionLifecycle {
    public private(set) var gate: AuthGate = .launching

    @ObservationIgnored private let source: any AccountSessionSource
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let flushTimeout: Duration
    @ObservationIgnored private var seeder: (any SessionSeeding)?
    @ObservationIgnored private var connectParticipants: [any SessionParticipant] = []
    @ObservationIgnored private var progressSources: [any SessionParticipant] = []
    @ObservationIgnored private var session: RunningSession?
    @ObservationIgnored private var launch: Task<Void, Never>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    /// The last queued transition; the next one waits for it.
    @ObservationIgnored private var tail: Task<Void, Never>?

    private struct RunningSession {
        let context: SessionContext
        /// In start order.
        let participants: [any SessionParticipant]
        let seed: Task<Void, Never>?
    }

    /// - Parameters:
    ///   - clock: Times the flush before a sign-out or switch; tests pass a manual clock.
    ///   - flushTimeout: How long a sign-out or switch waits for the flush before it continues.
    ///     Unsent work stays in the durable stores.
    public init(
        source: any AccountSessionSource,
        clock: any Clock<Duration> = ContinuousClock(),
        flushTimeout: Duration = .seconds(3)
    ) {
        self.source = source
        self.clock = clock
        self.flushTimeout = flushTimeout
    }

    /// A lifecycle whose gate shows ``AuthGate/storeUnavailable(_:)`` once started, for when the
    /// local store couldn't be opened and no account source can be built.
    public convenience init(storeUnavailable error: any Error) {
        self.init(source: UnavailableAccountSource(error: error))
    }

    // MARK: Registration

    /// Adds a participant to the pipeline. It takes part from the next session that starts.
    public func register(_ participant: any SessionParticipant, stage: SessionStage) {
        switch stage {
        case .connect: connectParticipants.append(participant)
        case .progressSource: progressSources.append(participant)
        }
    }

    /// Sets the library seeder, which also starts first and ends last. It takes part from the
    /// next session that starts.
    public func register(seeder: any SessionSeeding) {
        self.seeder = seeder
    }

    // MARK: Transitions

    /// Restores the saved session and starts following the account. Safe to call from every
    /// scene and CarPlay: only the first call runs, and every call returns once it's done.
    public func start() async {
        if let launch {
            await launch.value
            return
        }
        let task = Task { await self.run() }
        launch = task
        await task.value
    }

    /// Flushes and ends the session, then signs out.
    /// - Returns: An OpenID end-session URL to open, if the server returned one.
    @discardableResult
    public func signOut() async -> URL? {
        await serialized {
            await self.endFlushing(.signOut)
            self.gate = .connect
            let url = await self.source.logout()
            await self.reconcile()
            return url
        }
    }

    /// Flushes and ends the session, then switches to another saved connection and starts its
    /// session. If the switch fails and the account stays on the old connection, its session
    /// starts again.
    public func switchAccount(to connectionID: UUID) async throws {
        let result: Result<Void, any Error> = await serialized {
            if self.session?.context.identity.connectionID == connectionID { return .success(()) }
            await self.endFlushing(.switch)
            let result: Result<Void, any Error>
            do {
                try await self.source.switch(to: connectionID)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            await self.reconcile()
            return result
        }
        try result.get()
    }

    /// Flushes the session when a scene goes to the background, waiting at most the flush
    /// timeout.
    public func handle(scenePhase: SessionScenePhase) async {
        guard scenePhase == .background else { return }
        await serialized { await self.flush() }
    }

    // MARK: Pipeline

    private func run() async {
        let restored = await serialized { () -> Bool in
            do {
                try await self.source.restore()
            } catch {
                self.gate = .storeUnavailable(SessionStoreError(error))
                return false
            }
            await self.reconcile()
            return true
        }
        guard restored else { return }
        let source = self.source
        observation = Task { [weak self] in
            for await _ in Observations({ @MainActor in source.phase }) {
                guard let self else { return }
                await self.serialized { await self.reconcile() }
            }
        }
    }

    /// Brings the session and gate in line with the source's phase, until the phase stops
    /// changing.
    private func reconcile() async {
        var handled: AccountSessionPhase?
        while source.phase != handled {
            let phase = source.phase
            handled = phase
            switch phase {
            case .restoring:
                // Keep the gate: launching at launch, or the old identity during a switch.
                break
            case .signedOut:
                await end(.expired)
                if case .storeUnavailable = gate { break }
                gate = .connect
            case .active(let identity, let isOffline):
                if session?.context.identity != identity {
                    await end(.switch)
                    await begin(SessionContext(identity: identity, client: source.client, isOffline: isOffline))
                }
                gate = .ready(identity, isOffline: isOffline)
            }
        }
    }

    private func begin(_ context: SessionContext) async {
        var started: [any SessionParticipant] = []
        if let seeder {
            await seeder.sessionDidStart(context)
            started.append(seeder)
        }
        for participant in connectParticipants {
            await participant.sessionDidStart(context)
            started.append(participant)
        }
        await seeder?.beginSeed(context)
        for participant in progressSources {
            await participant.sessionDidStart(context)
            started.append(participant)
        }
        let seed = seeder.map { seeder in Task { await seeder.seed(context) } }
        session = RunningSession(context: context, participants: started, seed: seed)
    }

    /// Ends the running session, if any, without flushing.
    private func end(_ reason: SessionEndReason) async {
        guard let session else { return }
        self.session = nil
        session.seed?.cancel()
        for participant in session.participants.reversed() {
            await participant.sessionWillEnd(reason)
        }
    }

    private func endFlushing(_ reason: SessionEndReason) async {
        await flush()
        await end(reason)
    }

    /// Flushes every participant, in reverse start order, for at most `flushTimeout`; then
    /// cancels a flush that's still running.
    private func flush() async {
        guard let participants = session?.participants, !participants.isEmpty else { return }
        let clock = clock
        let timeout = flushTimeout
        let done = FirstSignal()
        let flush = Task {
            for participant in participants.reversed() {
                await participant.flush()
            }
            done.fire()
        }
        let timer = Task {
            try? await clock.sleep(for: timeout)
            done.fire()
        }
        await done.wait()
        flush.cancel()
        timer.cancel()
    }

    /// Runs `body` after every transition queued before it.
    private func serialized<T: Sendable>(_ body: @escaping @MainActor @Sendable () async -> T) async -> T {
        let previous = tail
        let task = Task {
            await previous?.value
            return await body()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }
}

/// Resumes its waiter on the first ``fire()``.
@MainActor
private final class FirstSignal {
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func fire() {
        guard !fired else { return }
        fired = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        guard !fired else { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

/// The source of ``SessionLifecycle/init(storeUnavailable:)``: never signed in, and its restore
/// throws the store's error.
@MainActor @Observable
private final class UnavailableAccountSource: AccountSessionSource {
    let phase = AccountSessionPhase.signedOut
    let client: APIClient? = nil
    private let error: any Error

    init(error: any Error) {
        self.error = error
    }

    func restore() async throws { throw error }
    func logout() async -> URL? { nil }
    func `switch`(to connectionID: UUID) async throws { throw error }
}
