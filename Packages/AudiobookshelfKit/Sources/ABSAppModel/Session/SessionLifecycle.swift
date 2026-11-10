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
/// back online or gets a new client, the session reconnects: the old seed is cancelled,
/// ``SessionSeeding/beginSeed(_:)`` marks a new boundary, every participant gets
/// ``SessionParticipant/sessionDidReconnect(_:)`` in start order, then a new seed runs. The
/// library stays connected to the same identity through a reconnect, so the boundary comes
/// first: the progress sources keep running, and anything they apply while a reconnect hook is
/// suspended lands after the boundary and survives the seed.
///
/// **End order.** The started participants end in reverse start order, so the progress sources
/// stop before the library clears, and only then does the account sign out, switch or get
/// removed. A switch from A to B ends A completely before B's pipeline starts. Before a sign-out,
/// switch or removal, every participant flushes, for at most `flushTimeout`; the teardown then
/// gets another `flushTimeout` in all. When the account's identity disappears by itself (the
/// server rejected the session), the same teardown runs with ``SessionEndReason/expired`` and
/// without a flush.
///
/// **A stale session.** The source can move on (expire, or show another account) before its
/// observation is reconciled. Every entry point that acts on the running session first checks
/// the source: a session it has left is ended (as expired, or as a switch) without a flush, and
/// participants never start, reconnect or flush for a session the source has already left.
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
    /// How many ``performAccountChange(_:)`` calls are running. No session starts until the
    /// last one finishes; an expiry still ends one.
    @ObservationIgnored private var accountChanges = 0
    @ObservationIgnored private var lastSessionID: UInt64 = 0
    @ObservationIgnored private var flushWorkers: [UInt64: [UInt64: Task<Void, Never>]] = [:]
    @ObservationIgnored private var lastFlushWorkerID: UInt64 = 0
    /// The session whose pipeline is starting, before it becomes ``session``.
    @ObservationIgnored private var beginning: SessionContext?
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
    /// How many of the source's changes the observation has reconciled, its first value
    /// included. Tests wait for it so the observation is idle before they change the source.
    @ObservationIgnored private(set) var reconciledObservations = 0

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
            if let context = session?.context ?? beginning { requestSignOut(of: context) }
            return nil
        }
        return await serialized { await self.performSignOut() }
    }

    /// Queues a sign-out of the session `context` describes, after the transitions already
    /// queued, without waiting for it. For participants and their tasks, for example on a
    /// rejected request; pass the participant's ``SessionContext``. When the sign-out's turn
    /// comes, it does nothing unless that same session (by ``SessionContext/sessionID``, not
    /// just the identity) is still running and the source hasn't moved to another identity, so
    /// a request from an ended session can't sign out a later one, even of the same account.
    /// If the source already signed out by itself, the session ends as expired instead, without
    /// a flush. There's no OpenID end-session URL to open this way.
    public func requestSignOut(of context: SessionContext) {
        _ = enqueue {
            if self.source.phase == .signedOut {
                await self.reconcile()
                return
            }
            guard let running = self.session, running.context.sessionID == context.sessionID,
                !self.sourceHasLeft(running.context.identity)
            else {
                Log.auth.info("Ignored a sign-out request from an ended session")
                return
            }
            _ = await self.performSignOut(expectedIdentity: running.context.identity)
        }
    }

    /// Flushes and ends the session, shows ``AuthGate/switching(from:)``, then switches to
    /// another saved connection and starts its session. If the switch fails and the account
    /// stays on the old connection, its session starts again.
    public func switchAccount(to connectionID: UUID) async throws {
        if rejectReentrant("switchAccount(to:)") { return }
        let result: Result<Void, any Error> = await serialized {
            await self.endStaleSession()
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
            await self.endStaleSession()
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
    /// again. No session starts while any change's body runs, so overlapping calls (say, from
    /// two scenes) follow the account once, when the last one finishes. An expiry during a body
    /// still ends whatever is running.
    ///
    /// The gate changes while `body` runs, so present the sign-in UI (the web sign-in's
    /// presentation anchor) outside the gated content, or keep the current shell on screen
    /// while the gate is ``AuthGate/switching(from:)``; otherwise the sign-in is torn down
    /// with the shell.
    public func performAccountChange(_ body: @MainActor () async throws -> Void) async rethrows {
        if rejectReentrant("performAccountChange(_:)") { return }
        accountChanges += 1
        await serialized { await self.endForAccountChange() }
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
    /// start no transitions. When the source has already left the session (expired, or shows
    /// another account), it doesn't flush; it queues a reconcile, which ends the session.
    public func handle(scenePhase: SessionScenePhase) async {
        guard scenePhase == .background, let running = session else { return }
        guard !sourceHasLeft(running.context.identity) else {
            _ = enqueue { await self.reconcile() }
            return
        }
        await flush(running.participants, sessionID: running.context.sessionID)
    }

    private func performSignOut(expectedIdentity: SessionIdentity? = nil) async -> URL? {
        await endStaleSession()
        guard source.phase != .signedOut else {
            // Signed out by itself and not reconciled yet: an expiry, not a sign-out.
            await reconcile()
            return nil
        }
        if let identity = session?.context.identity { gate = .signingOut(from: identity) }
        await endFlushing(.signOut)
        if let expectedIdentity, sourceHasLeft(expectedIdentity) {
            await reconcile()
            return nil
        }
        showConnect()
        let url = await source.logout()
        await reconcile()
        return url
    }

    private func finishAccountChange() async {
        await serialized {
            self.accountChanges -= 1
            guard self.accountChanges == 0 else { return }
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
                self.reconciledObservations += 1
            }
        }
    }

    /// Brings the session and gate in line with the source, until the source stops changing.
    private func reconcile() async {
        if case .storeUnavailable = gate { return }
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
                await end(.expired)
                showConnect()
            case .active(let identity, let isOffline):
                // Deferred to the last account change's end; the gate stays switching.
                guard accountChanges == 0 else { break }
                if let running = session, running.context.identity == identity {
                    await update(running, to: running.context.with(client: client, isOffline: isOffline))
                } else if session != nil {
                    await end(.switch)
                    // The source may have moved on during the teardown; look again before starting.
                    handled = nil
                    continue
                } else {
                    lastSessionID += 1
                    await begin(
                        SessionContext(
                            identity: identity, client: client, isOffline: isOffline, sessionID: lastSessionID))
                }
                if session?.context.identity == identity, !sourceHasLeft(identity) {
                    gate = .ready(identity, isOffline: isOffline)
                }
            }
        }
    }

    private func begin(_ context: SessionContext) async {
        beginning = context
        defer { beginning = nil }
        let seeder = self.seeder
        let connect: [any SessionParticipant] = (seeder.map { [$0] } ?? []) + connectParticipants
        // Once the source leaves the identity, start nothing more: the session keeps only what
        // started, and the reconcile loop ends it next.
        var startedConnect: [any SessionParticipant] = []
        var startedSources: [any SessionParticipant] = []
        for participant in connect {
            guard !sourceHasLeft(context.identity) else { break }
            await participant.sessionDidStart(context)
            startedConnect.append(participant)
        }
        if startedConnect.count == connect.count, !sourceHasLeft(context.identity) {
            await seeder?.beginSeed(context)
            for participant in progressSources {
                guard !sourceHasLeft(context.identity) else { break }
                await participant.sessionDidStart(context)
                startedSources.append(participant)
            }
        }
        let isComplete = startedSources.count == progressSources.count && !sourceHasLeft(context.identity)
        session = RunningSession(
            context: context, seeder: startedConnect.isEmpty ? nil : seeder, connect: startedConnect,
            progressSources: startedSources, seed: isComplete ? startSeed(seeder, context) : nil)
    }

    /// Runs the online part of the pipeline again when the identity came back online or got a
    /// new client.
    private func update(_ running: RunningSession, to context: SessionContext) async {
        let reconnected =
            (running.context.isOffline && !context.isOffline) || running.context.client !== context.client
        session?.context = context
        guard reconnected else { return }
        running.seed?.cancel()
        // The boundary first: progress applied while a hook below is suspended survives the seed.
        await running.seeder?.beginSeed(context)
        for participant in running.participants {
            guard !sourceHasLeft(context.identity) else { return }
            await participant.sessionDidReconnect(context)
        }
        guard !sourceHasLeft(context.identity) else { return }
        session?.seed = startSeed(running.seeder, context)
    }

    private func startSeed(_ seeder: (any SessionSeeding)?, _ context: SessionContext) -> Task<Void, Never>? {
        guard let seeder else { return nil }
        return Task { await seeder.seed(context) }
    }

    /// Ends the running session, if any, without flushing.
    ///
    /// Before anything suspends, a gate still showing ``AuthGate/ready(_:isOffline:)`` moves on,
    /// so the root never shows a shell whose services are stopping: to
    /// ``AuthGate/switching(from:)`` for a switch, which also covers the next session's start,
    /// and to ``AuthGate/signingOut(from:)`` otherwise. A gate a transition already set is kept.
    ///
    /// The whole teardown shares one `flushTimeout` budget. Every participant is still called in
    /// order, but once the budget is spent the lifecycle waits for each only until its
    /// synchronous part ran, then cancels it and moves on.
    private func end(_ reason: SessionEndReason) async {
        guard let running = session else { return }
        session = nil
        running.seed?.cancel()
        if let workers = flushWorkers.removeValue(forKey: running.context.sessionID) {
            for worker in workers.values { worker.cancel() }
        }
        if case .ready = gate {
            let identity = running.context.identity
            gate = reason == .switch ? .switching(from: identity) : .signingOut(from: identity)
        }
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

    /// Flushes and ends the session with `reason`; or, when the source already signed out by
    /// itself (an expiry not reconciled yet), ends it as expired without flushing.
    private func endFlushing(_ reason: SessionEndReason) async {
        guard let running = session else { return }
        guard source.phase != .signedOut else {
            await end(.expired)
            return
        }
        await flush(running.participants, sessionID: running.context.sessionID)
        await end(reason)
    }

    /// Whether the source no longer shows `identity`: it signed out or shows another account.
    /// While it restores, it hasn't left yet.
    private func sourceHasLeft(_ identity: SessionIdentity) -> Bool {
        switch source.phase {
        case .signedOut: true
        case .restoring: false
        case .active(let current, _): current != identity
        }
    }

    /// Ends the running session, without a flush, if the source has left it before its
    /// observation was reconciled: as expired when the source signed out, as a switch when it
    /// shows another account. Starts nothing; the caller's reconcile does.
    private func endStaleSession() async {
        guard let identity = session?.context.identity, sourceHasLeft(identity) else { return }
        if source.phase == .signedOut {
            await end(.expired)
            showConnect()
        } else {
            gate = .switching(from: identity)
            await end(.switch)
        }
    }

    private func endForAccountChange() async {
        await endStaleSession()
        guard let identity = session?.context.identity else { return }
        gate = .switching(from: identity)
        await endFlushing(.switch)
    }

    /// Flushes `participants` concurrently, for at most `flushTimeout` in all; then cancels the
    /// flushes still running. The timeout doesn't wait for a flush that ignores cancellation.
    private func flush(_ participants: [any SessionParticipant], sessionID: UInt64) async {
        let clock = clock
        let timeout = flushTimeout
        let done = Signal()
        lastFlushWorkerID += 1
        let workerID = lastFlushWorkerID
        let worker = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for participant in participants.reversed() {
                    group.addTask { await participant.flush() }
                }
            }
            self?.removeFlushWorker(sessionID: sessionID, workerID: workerID)
            done.fire()
        }
        flushWorkers[sessionID, default: [:]][workerID] = worker
        let timer = Task {
            try? await clock.sleep(for: timeout)
            done.fire()
        }
        await done.wait()
        worker.cancel()
        timer.cancel()
    }

    private func removeFlushWorker(sessionID: UInt64, workerID: UInt64) {
        flushWorkers[sessionID]?[workerID] = nil
        if flushWorkers[sessionID]?.isEmpty == true {
            flushWorkers[sessionID] = nil
        }
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

extension SessionContext {
    fileprivate func with(client: APIClient?, isOffline: Bool) -> SessionContext {
        SessionContext(identity: identity, client: client, isOffline: isOffline, sessionID: sessionID)
    }
}
