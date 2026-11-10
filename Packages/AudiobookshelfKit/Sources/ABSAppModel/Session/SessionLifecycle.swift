import ABSAPI
import ABSCore
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
/// switch or removal, every participant flushes, for at most `flushTimeout`; the teardown then
/// gets another `flushTimeout` in all. When the account's identity disappears by itself (the
/// server rejected the session), the same teardown runs with ``SessionEndReason/expired`` and
/// without a flush.
///
/// Transitions run one at a time on the main actor, in call order. Participants must not await
/// a transition from inside one; they call ``requestSignOut(of:)``, which queues a sign-out
/// without waiting.
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
    /// The session ``performAccountChange(_:)`` ended, and its client, while its body runs.
    @ObservationIgnored private var changingFrom: (identity: SessionIdentity, client: APIClient?)?
    /// How many ``performAccountChange(_:)`` calls are running; the last one to finish follows
    /// the account.
    @ObservationIgnored private var accountChanges = 0
    @ObservationIgnored private var launch: Task<Void, Never>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    /// The last queued transition; the next one waits for it.
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var lastTransitionID: UInt64 = 0
    /// The transition whose body is running, matched against ``TransitionScope/transitionID``.
    @ObservationIgnored private var runningTransition: UInt64?
    /// Reports a transition called from inside a running one, where it can't run. Tests record
    /// instead of stopping.
    @ObservationIgnored var reportMisuse: @MainActor (String) -> Void = { assertionFailure($0) }

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

    /// - Parameters:
    ///   - clock: Times the flush and teardown budgets; tests pass a manual clock.
    ///   - flushTimeout: How long the flush, and then the whole teardown, may take before the
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
    /// scene and CarPlay: only the first call runs, and every call returns once it's done (a
    /// call from inside the launch returns at once).
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
        guard !isReentrant, let launch else { return }
        await launch.value
    }

    /// Flushes and ends the session, then signs out. Does nothing when already signed out.
    /// From inside a transition, use ``requestSignOut(of:)`` instead.
    /// - Returns: An OpenID end-session URL to open, if the server returned one.
    @discardableResult
    public func signOut() async -> URL? {
        if rejectReentrant("signOut()") {
            if let identity = session?.context.identity ?? source.phase.identity {
                requestSignOut(of: identity)
            }
            return nil
        }
        return await serialized { await self.performSignOut() }
    }

    /// Queues a sign-out of `identity` after the transitions already queued, without waiting for
    /// it. For participants and their tasks, for example on a rejected request; pass the
    /// identity from their ``SessionContext``. When the sign-out's turn comes, it does nothing
    /// unless `identity` is still the active account, so a request from an ended session can't
    /// sign out the next one, nor during ``performAccountChange(_:)`` away from it. If the source
    /// already signed out by itself, the session ends as expired instead, without a flush.
    /// There's no OpenID end-session URL to open this way.
    public func requestSignOut(of identity: SessionIdentity) {
        _ = enqueue {
            if self.source.phase == .signedOut {
                await self.reconcile()
                return
            }
            let current = self.session?.context.identity ?? self.source.phase.identity
            let isChangingAway = self.session == nil && self.changingFrom?.identity == identity
            guard current == identity, !isChangingAway else {
                Log.auth.info("Ignored a sign-out request from an ended session")
                return
            }
            _ = await self.performSignOut()
        }
    }

    /// Flushes and ends the session, shows ``AuthGate/switching(from:)``, then switches to
    /// another saved connection and starts its session. If the switch fails and the account
    /// stays on the old connection, its session starts again.
    public func switchAccount(to connectionID: UUID) async throws {
        if rejectReentrant("switchAccount(to:)") { return }
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
        if rejectReentrant("removeAccount(_:)") { return nil }
        let result: Result<URL?, any Error> = await serialized {
            if let identity = self.session?.context.identity, identity.connectionID == connectionID {
                self.gate = .signingOut(from: identity)
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

    /// Signs in to another account while signed in: flushes and ends the session with
    /// ``SessionEndReason/switch``, shows ``AuthGate/switching(from:)``, runs `body` (the
    /// connect flow's sign-in), then follows wherever the account ended up, whether `body`
    /// returned, threw or was cancelled. If the account is still the old one, its session starts
    /// again. Overlapping calls (say, from two scenes) follow the account once the last one
    /// finishes.
    ///
    /// The gate changes while `body` runs, so present the sign-in UI (the web sign-in's
    /// presentation anchor) outside the gated content, or keep the current shell on screen
    /// while the gate is ``AuthGate/switching(from:)``; otherwise the sign-in is torn down
    /// with the shell.
    public func performAccountChange(_ body: @MainActor () async throws -> Void) async rethrows {
        if rejectReentrant("performAccountChange(_:)") { return }
        accountChanges += 1
        await serialized {
            guard let running = self.session else { return }
            await self.endForAccountChange()
            self.changingFrom = (running.context.identity, running.context.client)
        }
        do {
            try await body()
        } catch {
            await finishAccountChange()
            throw error
        }
        await finishAccountChange()
    }

    /// Flushes the running session when a scene goes to the background, for at most the flush
    /// timeout. It doesn't wait for, or hold up, other transitions. Called from a participant's
    /// task, its flush tasks carry that task's stale transition ID, which is harmless: they
    /// start no transitions.
    public func handle(scenePhase: SessionScenePhase) async {
        guard scenePhase == .background, let participants = session?.participants else { return }
        await flush(participants)
    }

    private func performSignOut() async -> URL? {
        guard session != nil || source.phase != .signedOut else { return nil }
        if let identity = session?.context.identity { gate = .signingOut(from: identity) }
        await endFlushing(.signOut)
        showConnect()
        let url = await source.logout()
        await reconcile()
        return url
    }

    private func finishAccountChange() async {
        await serialized {
            self.accountChanges -= 1
            guard self.accountChanges == 0 else { return }
            self.changingFrom = nil
            await self.reconcile()
        }
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
                } else if session != nil || !isWaitingForAccountChange(identity, client: client) {
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

    /// Whether `identity` is still the account ``performAccountChange(_:)`` left, on the same
    /// client; a new client means it signed in again.
    private func isWaitingForAccountChange(_ identity: SessionIdentity, client: APIClient?) -> Bool {
        guard let changingFrom, changingFrom.identity == identity else { return false }
        return client == nil || client === changingFrom.client
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
        return Task { await seeder.seed(context) }
    }

    /// Ends the running session, if any, without flushing.
    ///
    /// The whole teardown shares one `flushTimeout` budget. Every participant is still called in
    /// order, but once the budget is spent the lifecycle waits for each only until its
    /// synchronous part ran, then cancels it and moves on.
    private func end(_ reason: SessionEndReason) async {
        guard let running = session else { return }
        session = nil
        running.seed?.cancel()
        let clock = clock
        let timeout = flushTimeout
        let deadline = Deadline()
        let timer = Task {
            try? await clock.sleep(for: timeout)
            deadline.pass()
        }
        for participant in running.participants.reversed() {
            let started = Signal()
            let step = Signal()
            let finished = Signal()
            let worker = Task {
                started.fire()
                await participant.sessionWillEnd(reason)
                finished.fire()
                step.fire()
            }
            // The worker's synchronous part runs in the same main-actor job as `started.fire()`.
            await started.wait()
            await deadline.wait(for: step)
            if !finished.isFired { worker.cancel() }
        }
        timer.cancel()
    }

    private func endFlushing(_ reason: SessionEndReason) async {
        guard let participants = session?.participants else { return }
        await flush(participants)
        await end(reason)
    }

    private func endForAccountChange() async {
        guard let identity = session?.context.identity else { return }
        gate = .switching(from: identity)
        await endFlushing(.switch)
    }

    /// Flushes `participants` concurrently, for at most `flushTimeout` in all; then cancels the
    /// flushes still running. The timeout doesn't wait for a flush that ignores cancellation.
    private func flush(_ participants: [any SessionParticipant]) async {
        let clock = clock
        let timeout = flushTimeout
        let done = Signal()
        let worker = Task {
            await withTaskGroup(of: Void.self) { group in
                for participant in participants.reversed() {
                    group.addTask { await participant.flush() }
                }
            }
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

    /// Whether the caller runs inside the transition that's running now, where awaiting the
    /// queue would deadlock. A task a participant spawned carries its transition's ID, which
    /// stops matching once that transition finishes.
    private var isReentrant: Bool {
        guard let id = TransitionScope.transitionID else { return false }
        return id == runningTransition
    }

    /// Fails `operation` when called from inside the running transition.
    private func rejectReentrant(_ operation: StaticString) -> Bool {
        guard isReentrant else { return false }
        Log.auth.fault("\(operation, privacy: .public) was called from inside a session transition")
        reportMisuse("\(operation) was called from inside a session transition")
        return true
    }

    /// Queues `body` after every transition queued before it.
    private func enqueue<T: Sendable>(_ body: @escaping @MainActor @Sendable () async -> T) -> Task<T, Never> {
        let previous = tail
        let task = Task {
            await previous?.value
            self.lastTransitionID += 1
            let id = self.lastTransitionID
            self.runningTransition = id
            let value = await TransitionScope.$transitionID.withValue(id) { await body() }
            self.runningTransition = nil
            return value
        }
        tail = Task { _ = await task.value }
        return task
    }

    private func serialized<T: Sendable>(_ body: @escaping @MainActor @Sendable () async -> T) async -> T {
        await enqueue(body).value
    }
}

/// The ``SessionLifecycle`` transition the current task belongs to, including the participant
/// calls it makes and the tasks they start.
private enum TransitionScope {
    @TaskLocal static var transitionID: UInt64?
}

/// Lets its waiter through once fired.
@MainActor
private final class Signal {
    private(set) var isFired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func fire() {
        guard !isFired else { return }
        isFired = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        guard !isFired else { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

/// A teardown budget: waits for a step only until the budget is spent.
@MainActor
private final class Deadline {
    private var hasPassed = false
    private var step: Signal?

    func pass() {
        hasPassed = true
        step?.fire()
    }

    func wait(for step: Signal) async {
        guard !hasPassed else { return }
        self.step = step
        await step.wait()
        self.step = nil
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
