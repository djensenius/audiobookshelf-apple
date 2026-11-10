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
/// boundary: progress it applies is never dropped by the seed. When the same identity comes
/// back online or gets a new client, the pipeline runs again with
/// ``SessionParticipant/sessionDidReconnect(_:)`` and a new seed.
///
/// **End order.** The started participants end in reverse start order, so the progress sources
/// stop before the library clears, and only then does the account sign out, switch or get
/// removed. A switch from A to B ends A completely before B's pipeline starts. Before a sign-out,
/// switch or removal, every participant flushes, for at most `flushTimeout`. When the account's
/// identity disappears by itself (the server rejected the session), the same teardown runs with
/// ``SessionEndReason/expired`` and without a flush.
///
/// Transitions run one at a time on the main actor, in call order. A transition requested from
/// inside a running one (by a participant) runs after it, without waiting.
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
    /// Set by ``prepareForAccountChange()``: its identity isn't restarted until the account
    /// changes or ``cancelAccountChange()``.
    @ObservationIgnored private var changingFrom: SessionIdentity?
    @ObservationIgnored private var launch: Task<Void, Never>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    /// The last queued transition; the next one waits for it.
    @ObservationIgnored private var tail: Task<Void, Never>?
    /// Transitions requested from inside a running one.
    @ObservationIgnored private var pending: [PendingRequest] = []

    private struct RunningSession {
        var context: SessionContext
        let seeder: (any SessionSeeding)?
        /// The seeder first, then the other connect participants.
        let connect: [any SessionParticipant]
        let progressSources: [any SessionParticipant]
        var seed: Task<Void, Never>?

        /// In start order.
        var participants: [any SessionParticipant] { connect + progressSources }
    }

    private enum PendingRequest {
        case signOut
        case switchAccount(UUID)
        case removeAccount(UUID)
        case prepareForAccountChange
        case cancelAccountChange
    }

    /// - Parameters:
    ///   - clock: Times the flush and teardown bounds; tests pass a manual clock.
    ///   - flushTimeout: How long a flush, and each participant's teardown, may take before the
    ///     lifecycle continues. Unsent work stays in the durable stores.
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

    /// Adds a participant to the pipeline. Register everything before ``start()``.
    public func register(_ participant: any SessionParticipant, stage: SessionStage) {
        if launch != nil { assertionFailure("Register session participants before start()") }
        switch stage {
        case .connect: connectParticipants.append(participant)
        case .progressSource: progressSources.append(participant)
        }
    }

    /// Sets the library seeder, which also starts first and ends last. Register it once, before
    /// ``start()``.
    public func register(seeder: any SessionSeeding) {
        precondition(self.seeder == nil, "A session lifecycle has one seeder")
        if launch != nil { assertionFailure("Register the seeder before start()") }
        self.seeder = seeder
    }

    // MARK: Transitions

    /// Restores the saved session and starts following the account. Safe to call from every
    /// scene and CarPlay: only the first call runs, and every call returns once it's done.
    ///
    /// If the source's `restore()` throws, the gate shows ``AuthGate/storeUnavailable(_:)`` for
    /// the rest of this instance's life; nothing retries it.
    public func start() async {
        if launch == nil {
            let restore = enqueue { () -> Bool in
                do {
                    try await self.source.restore()
                } catch {
                    self.gate = .storeUnavailable(SessionStoreError(error))
                    return false
                }
                await self.reconcile()
                return true
            }
            launch = Task {
                guard await restore.value else { return }
                self.observeSource()
            }
        }
        guard !TransitionScope.isActive, let launch else { return }
        await launch.value
    }

    /// Flushes and ends the session, then signs out. Does nothing when already signed out.
    /// - Returns: An OpenID end-session URL to open, if the server returned one.
    @discardableResult
    public func signOut() async -> URL? {
        if deferIfInTransition(.signOut) { return nil }
        return await serialized {
            guard self.session != nil || self.source.phase != .signedOut else { return nil }
            await self.endFlushing(.signOut)
            self.showConnect()
            let url = await self.source.logout()
            await self.reconcile()
            return url
        }
    }

    /// Flushes and ends the session, shows ``AuthGate/switching(from:)``, then switches to
    /// another saved connection and starts its session. If the switch fails and the account
    /// stays on the old connection, its session starts again.
    public func switchAccount(to connectionID: UUID) async throws {
        if deferIfInTransition(.switchAccount(connectionID)) { return }
        let result: Result<Void, any Error> = await serialized {
            if self.session?.context.identity.connectionID == connectionID { return .success(()) }
            await self.endForAccountChange()
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

    /// Forgets a saved connection. Removing the active one flushes and ends its session with
    /// ``SessionEndReason/removed`` first; removing another one just calls through.
    /// - Returns: An OpenID end-session URL to open, if the server returned one.
    @discardableResult
    public func removeAccount(_ connectionID: UUID) async throws -> URL? {
        if deferIfInTransition(.removeAccount(connectionID)) { return nil }
        let result: Result<URL?, any Error> = await serialized {
            if self.session?.context.identity.connectionID == connectionID {
                await self.endFlushing(.removed)
                self.showConnect()
            }
            let result: Result<URL?, any Error>
            do {
                result = .success(try await self.source.remove(connectionID))
            } catch {
                result = .failure(error)
            }
            await self.reconcile()
            return result
        }
        return try result.get()
    }

    /// Flushes and ends the session with ``SessionEndReason/switch`` and shows
    /// ``AuthGate/switching(from:)``, before the connect flow signs in to another account while
    /// signed in. The new account's session starts when the source makes it active. If the
    /// sign-in fails or is cancelled, call ``cancelAccountChange()``.
    public func prepareForAccountChange() async {
        if deferIfInTransition(.prepareForAccountChange) { return }
        await serialized {
            guard let identity = self.session?.context.identity else { return }
            await self.endForAccountChange()
            self.changingFrom = identity
        }
    }

    /// Restarts the session that ``prepareForAccountChange()`` ended, if its account is still
    /// active.
    public func cancelAccountChange() async {
        if deferIfInTransition(.cancelAccountChange) { return }
        await serialized {
            self.changingFrom = nil
            await self.reconcile()
        }
    }

    /// Flushes the running session when a scene goes to the background, for at most the flush
    /// timeout. It doesn't wait for, or hold up, other transitions.
    public func handle(scenePhase: SessionScenePhase) async {
        guard scenePhase == .background, let participants = session?.participants else { return }
        await flush(participants)
    }

    // MARK: Pipeline

    private func observeSource() {
        let source = self.source
        // Not cancelled on deinit: the app keeps one lifecycle for the whole process. The loop
        // holds it weakly, so a released lifecycle's loop ends at the source's next change.
        observation = Task { [weak self] in
            let changes = Observations { @MainActor in
                (source.phase, source.client.map { ObjectIdentifier($0) })
            }
            for await _ in changes {
                guard let self else { return }
                await self.serialized { await self.reconcile() }
            }
        }
    }

    /// Brings the session and gate in line with the source, until the source stops changing.
    private func reconcile() async {
        var handled: AccountSessionPhase?
        var handledClient: APIClient?
        while handled != source.phase || handledClient !== source.client {
            let phase = source.phase
            let client = source.client
            handled = phase
            handledClient = client
            switch phase {
            case .restoring:
                // Keep the gate: launching at launch, or switching during a switch.
                break
            case .signedOut:
                changingFrom = nil
                await end(.expired)
                showConnect()
            case .active(let identity, let isOffline):
                let context = SessionContext(identity: identity, client: client, isOffline: isOffline)
                if let running = session, running.context.identity == identity {
                    await update(running, to: context)
                } else if session != nil || changingFrom != identity {
                    changingFrom = nil
                    await end(.switch)
                    await begin(context)
                }
                if session?.context.identity == identity {
                    gate = .ready(identity, isOffline: isOffline)
                }
            }
        }
    }

    private func begin(_ context: SessionContext) async {
        let seeder = self.seeder
        let connect: [any SessionParticipant] = (seeder.map { [$0] } ?? []) + connectParticipants
        let progressSources = self.progressSources
        for participant in connect {
            await participant.sessionDidStart(context)
        }
        await seeder?.beginSeed(context)
        for participant in progressSources {
            await participant.sessionDidStart(context)
        }
        // Don't seed a session the source already left; the reconcile loop ends it next.
        let isCurrent = source.phase.identity == context.identity
        session = RunningSession(
            context: context, seeder: seeder, connect: connect, progressSources: progressSources,
            seed: isCurrent ? startSeed(seeder, context) : nil)
    }

    /// Runs the online part of the pipeline again when the identity came back online or got a
    /// new client.
    private func update(_ running: RunningSession, to context: SessionContext) async {
        let reconnected =
            (running.context.isOffline && !context.isOffline) || running.context.client !== context.client
        session?.context = context
        guard reconnected else { return }
        running.seed?.cancel()
        for participant in running.connect {
            await participant.sessionDidReconnect(context)
        }
        await running.seeder?.beginSeed(context)
        for participant in running.progressSources {
            await participant.sessionDidReconnect(context)
        }
        guard source.phase.identity == context.identity else { return }
        session?.seed = startSeed(running.seeder, context)
    }

    private func startSeed(_ seeder: (any SessionSeeding)?, _ context: SessionContext) -> Task<Void, Never>? {
        guard let seeder else { return nil }
        return TransitionScope.$isActive.withValue(false) {
            Task { await seeder.seed(context) }
        }
    }

    /// Ends the running session, if any, without flushing. Each participant gets at most the
    /// flush timeout.
    private func end(_ reason: SessionEndReason) async {
        guard let running = session else { return }
        session = nil
        running.seed?.cancel()
        for participant in running.participants.reversed() {
            await withinTimeout { await participant.sessionWillEnd(reason) }
        }
    }

    private func endFlushing(_ reason: SessionEndReason) async {
        guard let participants = session?.participants else { return }
        await flush(participants)
        await end(reason)
    }

    private func endForAccountChange() async {
        guard let identity = session?.context.identity else { return }
        await endFlushing(.switch)
        gate = .switching(from: identity)
    }

    /// Flushes `participants` concurrently, for at most `flushTimeout` in all; then cancels the
    /// flushes still running.
    private func flush(_ participants: [any SessionParticipant]) async {
        await withinTimeout {
            await withTaskGroup(of: Void.self) { group in
                for participant in participants.reversed() {
                    group.addTask { await participant.flush() }
                }
            }
        }
    }

    /// Runs `work` until it finishes or `flushTimeout` passes, whichever is first, then cancels
    /// it. It isn't awaited after the timeout, so work that ignores cancellation can't hold up
    /// the lifecycle.
    private func withinTimeout(_ work: @escaping @MainActor @Sendable () async -> Void) async {
        let clock = clock
        let timeout = flushTimeout
        let done = FirstSignal()
        let worker = Task {
            await work()
            done.fire()
        }
        let timer = Task {
            try? await clock.sleep(for: timeout)
            done.fire()
        }
        await done.wait()
        worker.cancel()
        timer.cancel()
    }

    private func showConnect() {
        if case .storeUnavailable = gate { return }
        gate = .connect
    }

    // MARK: Queue

    /// Records `request` to run after the current transition when called from inside one, where
    /// waiting for the queue would deadlock.
    private func deferIfInTransition(_ request: PendingRequest) -> Bool {
        guard TransitionScope.isActive else { return false }
        pending.append(request)
        return true
    }

    private func perform(_ request: PendingRequest) async {
        switch request {
        case .signOut: await signOut()
        case .switchAccount(let id): try? await switchAccount(to: id)
        case .removeAccount(let id): _ = try? await removeAccount(id)
        case .prepareForAccountChange: await prepareForAccountChange()
        case .cancelAccountChange: await cancelAccountChange()
        }
    }

    /// Queues `body` after every transition queued before it.
    private func enqueue<T: Sendable>(_ body: @escaping @MainActor @Sendable () async -> T) -> Task<T, Never> {
        let previous = tail
        let task = Task {
            await previous?.value
            let value = await TransitionScope.$isActive.withValue(true) { await body() }
            if !self.pending.isEmpty {
                let requests = self.pending
                self.pending = []
                TransitionScope.$isActive.withValue(false) {
                    _ = Task { for request in requests { await self.perform(request) } }
                }
            }
            return value
        }
        tail = Task { _ = await task.value }
        return task
    }

    private func serialized<T: Sendable>(_ body: @escaping @MainActor @Sendable () async -> T) async -> T {
        await enqueue(body).value
    }
}

/// Whether the current task is running a ``SessionLifecycle`` transition, including the
/// participant calls it makes.
private enum TransitionScope {
    @TaskLocal static var isActive = false
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
    func remove(_ connectionID: UUID) async throws -> URL? { throw error }
}
