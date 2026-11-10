import ABSAPI
import ABSCore
import ABSData
import Foundation

/// Why a part failed. Stable, unlike the English message.
public enum DownloadFailureCode: String, Sendable, Equatable {
    /// The transfer failed (network, timeout, server error status).
    case transfer
    /// The server answered with a status that won't change on retry.
    case httpStatus
    /// The server rejected the access token again after a refresh.
    case unauthorized
    /// A redirect dropped the `Authorization` header and the new address answered 401.
    case redirectedUnauthorized
    /// A redirect left the server; the body was discarded.
    case offOrigin
    /// The body was an HTML page, not the file.
    case unexpectedContent
    /// The body's size isn't the file's size.
    case sizeMismatch
    /// The file couldn't be moved into place.
    case fileSystem
    /// The device is out of space.
    case outOfSpace
    /// No credentials: the connection is signed out or the refresh failed.
    case credentials
    /// The resume data couldn't be read now (for example the device is locked).
    case resumeData
    /// The part's destination path is invalid.
    case invalidDestination
}

/// A durable change the engine reports. Every update is delivered; live progress is on
/// ``DownloadEngine/progress``, and ``DownloadStore`` holds the durable state.
public enum DownloadUpdate: Sendable, Equatable {
    case partCompleted(partID: UUID, recordID: UUID)
    /// `willRetry` is `false` when the part failed for good: its record is now `failed`, and
    /// its other parts are stopped (keeping their resume data) and queued.
    case partFailed(partID: UUID, recordID: UUID, code: DownloadFailureCode, message: String, willRetry: Bool)
    /// Every part completed: the record is now the local item `itemID` and was deleted.
    case recordComplete(recordID: UUID, itemID: UUID)
}

/// A part's live progress, throttled to about every 1% or 1 second.
public struct DownloadProgress: Sendable, Equatable {
    public var partID: UUID
    public var recordID: UUID
    public var bytesWritten: Int64
    public var expectedBytes: Int64
}

/// Downloads the parts of ``DownloadStore`` records with one background `URLSession` task
/// per part (#72).
///
/// - Each task's `taskDescription` is its part ID, which is how tasks are matched to parts
///   after a relaunch; the store's `taskIdentifier` is only a cache.
/// - Requests carry `Authorization: Bearer` and the custom headers, never `?token=`. The
///   access token is refreshed (or checked) before each task is created or resumed; a 401 for
///   the current token recreates the task from a fresh request once.
/// - Resume data from failed transfers is sealed in a ``ResumeDataVault`` and only used while
///   the credentials and network access it was created with are current (ADR 0007).
/// - Failures are retried with ``RetryPolicy`` backoff. When a part fails for good, its
///   record fails and its other parts stop, keeping their resume data.
/// - A complete record becomes a local item (`LocalItemStore.upsertFromDownload(_:)`) and is
///   deleted; activation repeats that for complete records left by a crash (ADR 0003).
///
/// Call ``activate()`` when the app comes to the foreground: it restarts the queued parts.
/// A background wake (``handleBackgroundEvents()``) only handles the session's events. Create
/// one engine per process: a background session identifier may only be used by one session
/// at a time.
public actor DownloadEngine {
    public static let sessionIdentifier = "org.davidjensenius.Audiobookshelf.downloads"

    private struct PartContext {
        var recordID: UUID
        var connectionID: UUID
        var serverPath: String
        var destination: URL?
        var expectedBytes: Int64
        var hasResumeData: Bool
    }

    /// Durable changes, for one consumer. Nothing is dropped.
    public nonisolated let updates: AsyncStream<DownloadUpdate>
    /// Live progress, for one consumer. Only the newest events are kept if it falls behind.
    public nonisolated let progress: AsyncStream<DownloadProgress>
    private let updateContinuation: AsyncStream<DownloadUpdate>.Continuation
    private let progressContinuation: AsyncStream<DownloadProgress>.Continuation
    private let store: DownloadStore
    private let localItems: LocalItemStore
    private let credentials: any DownloadCredentialProviding
    private let vault: ResumeDataVault
    private let locations: DownloadLocations
    private let retryPolicy: RetryPolicy
    private let networkAccess: @Sendable () async -> NetworkAccess
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    private let makeSession: DownloadSessionFactory
    private let registry: DownloadEngineRegistry
    private let readRecords: @Sendable (DownloadStore) async throws -> [DownloadRecordDTO]
    private let delegate = DownloadSessionDelegate()

    private var activation: Task<Bool, Never>?
    private var session: (any DownloadSession)?
    private var isEventLoopRunning = false
    private var isInvalidatingSession = false
    /// Set by ``activate()``: parts re-queued by the system are restarted at once.
    private var restartsQueuedParts = false
    private var contexts: [UUID: PartContext] = [:]
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    /// A token per launch in progress; ``stop(partIDs:keepingResumeData:)`` removes it.
    private var launching: [UUID: UUID] = [:]
    /// Parts to launch once the session is created again.
    private var deferredLaunches: Set<UUID> = []
    /// Parts being completed or failed for good; they keep their context (so a concurrent
    /// read doesn't bring back their old state) but can't launch.
    private var settling: Set<UUID> = []
    /// Bumped once a part has stopped, completed or failed for good, so a store read that
    /// overlapped the change is redone rather than bringing back the old state.
    private var epoch = 0
    private var retries: [UUID: Task<Void, Never>] = [:]
    private var failures: [UUID: Int] = [:]
    private var authRetried: Set<UUID> = []
    /// Tasks of the current session whose completion is ignored (cancelled or not ours).
    private var ignoredTasks: Set<Int> = []
    private var throttle = ProgressThrottle()
    private var backgroundWaiters: [CheckedContinuation<Void, Never>] = []
    /// Events-finished calls that came before their wake asked for them.
    private(set) var unclaimedBackgroundFinishes = 0

    /// - Parameters:
    ///   - networkAccess: the request flags for the current download cellular policy, read
    ///     when each task is created.
    ///   - makeSession: ``backgroundSession()`` in the app.
    public init(
        store: DownloadStore,
        localItems: LocalItemStore,
        credentials: any DownloadCredentialProviding,
        vault: ResumeDataVault,
        locations: DownloadLocations,
        retryPolicy: RetryPolicy = .default,
        networkAccess: @escaping @Sendable () async -> NetworkAccess,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = { .now },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        makeSession: @escaping DownloadSessionFactory = DownloadEngine.backgroundSession()
    ) {
        self.init(
            store: store, localItems: localItems, credentials: credentials, vault: vault, locations: locations,
            retryPolicy: retryPolicy, networkAccess: networkAccess, clock: clock, now: now, random: random,
            makeSession: makeSession, registry: .shared, readRecords: { try await $0.allRecords() })
    }

    init(
        store: DownloadStore,
        localItems: LocalItemStore,
        credentials: any DownloadCredentialProviding,
        vault: ResumeDataVault,
        locations: DownloadLocations,
        retryPolicy: RetryPolicy,
        networkAccess: @escaping @Sendable () async -> NetworkAccess,
        clock: any Clock<Duration>,
        now: @escaping @Sendable () -> Date,
        random: @escaping @Sendable () -> Double,
        makeSession: @escaping DownloadSessionFactory,
        registry: DownloadEngineRegistry,
        readRecords: @escaping @Sendable (DownloadStore) async throws -> [DownloadRecordDTO]
    ) {
        (updates, updateContinuation) = AsyncStream.makeStream()
        (progress, progressContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(100))
        self.store = store
        self.localItems = localItems
        self.credentials = credentials
        self.vault = vault
        self.locations = locations
        self.retryPolicy = retryPolicy
        self.networkAccess = networkAccess
        self.clock = clock
        self.now = now
        self.random = random
        self.makeSession = makeSession
        self.registry = registry
        self.readRecords = readRecords
        registry.register(self)
    }

    // MARK: - Public API

    /// Creates the session if needed, reattaches to the transfers that survived a relaunch,
    /// and restarts the parts of `queued` and `downloading` records that have no transfer.
    /// Call it when the app comes to the foreground.
    ///
    /// - Returns: `false` when the downloads couldn't be read; nothing was cancelled or
    ///   restarted, and a later call tries again.
    @discardableResult
    public func activate() async -> Bool {
        guard await ensureSession() else { return false }
        restartsQueuedParts = true
        delegate.post(.restartQueued)
        return true
    }

    /// Starts (or restarts) the given parts; parts that are already transferring are left
    /// alone. Retry counts start over.
    public func start(partIDs: [UUID]) async {
        guard await ensureSession() else { return }
        do {
            try await loadRecords()
        } catch {
            logError("Couldn't read downloads", error)
            return
        }
        for partID in partIDs where tasks[partID] == nil {
            retries.removeValue(forKey: partID)?.cancel()
            failures[partID] = nil
            authRetried.remove(partID)
            await launch(partID)
        }
    }

    /// Cancels the given parts' transfers and queues them again. With `keepingResumeData`
    /// the transfer's resume data is sealed so a later ``start(partIDs:)`` continues it;
    /// otherwise any resume data is deleted. The caller sets the record's state (for example
    /// `paused`), so a relaunch doesn't restart it.
    public func stop(partIDs: [UUID], keepingResumeData: Bool) async {
        for partID in partIDs {
            retries.removeValue(forKey: partID)?.cancel()
            launching[partID] = nil
            deferredLaunches.remove(partID)
            failures[partID] = nil
            authRetried.remove(partID)
            throttle.reset(partID)
            var hasResumeData: Bool? = keepingResumeData ? contexts[partID]?.hasResumeData : false
            if let task = tasks.removeValue(forKey: partID) {
                ignoredTasks.insert(task.taskIdentifier)
                if keepingResumeData, let data = await task.cancelByProducingResumeData() {
                    hasResumeData = seal(data, partID: partID, task: task)
                } else {
                    task.cancel()
                }
            }
            if !keepingResumeData { vault.delete(partID: partID) }
            if let hasResumeData { contexts[partID]?.hasResumeData = hasResumeData }
            await persist {
                try await $0.setPartState(.queued, partID: partID, taskIdentifier: nil, hasResumeData: hasResumeData)
            }
            epoch += 1
        }
    }

    /// Deletes the resume data of every part of `connectionID`'s downloads, for sign-out,
    /// removal or a credential change (ADR 0003). Their next start is a fresh request.
    public func discardResumeData(connectionID: UUID) async {
        let records = (try? await store.records(serverConnectionID: connectionID)) ?? []
        for part in records.flatMap(\.parts)
        where part.state != .completed && (part.hasResumeData || contexts[part.id]?.hasResumeData == true) {
            vault.delete(partID: part.id)
            contexts[part.id]?.hasResumeData = false
            await persist {
                try await $0.setPartState(
                    part.state, partID: part.id, taskIdentifier: part.taskIdentifier, error: part.lastError,
                    hasResumeData: false)
            }
        }
    }

    /// Call from `.backgroundTask(.urlSession(DownloadEngine.sessionIdentifier))` (through
    /// the static ``handleBackgroundEvents()``): creates the session if needed, then returns
    /// once it has delivered, and the engine has handled, the events of this wake. It doesn't
    /// restart queued parts.
    public func handleBackgroundEvents() async {
        guard await ensureSession() else { return }
        if unclaimedBackgroundFinishes > 0 {
            unclaimedBackgroundFinishes -= 1
            return
        }
        await withCheckedContinuation { backgroundWaiters.append($0) }
    }

    /// ``handleBackgroundEvents()`` on the process's engine, waiting up to 10 seconds for the
    /// app to create it. Without one it returns, and the events wait for the next session.
    public static func handleBackgroundEvents() async {
        await handleBackgroundEvents(registry: .shared, timeout: .seconds(10), clock: ContinuousClock())
    }

    static func handleBackgroundEvents(
        registry: DownloadEngineRegistry, timeout: Duration, clock: any Clock<Duration>
    ) async {
        guard let engine = await registry.engine(timeout: timeout, clock: clock) else {
            registry.abandonWake()
            Log.downloads.error("No download engine was created to handle background events")
            return
        }
        await engine.handleBackgroundEvents()
    }

    // MARK: - Session

    /// Creates the session once the downloads are read, reattaching to surviving transfers.
    /// Returns `false` without a session when the read fails; the next call tries again.
    @discardableResult
    func ensureSession() async -> Bool {
        let activation = activation ?? Task { await performActivation() }
        self.activation = activation
        return await activation.value
    }

    private func performActivation() async -> Bool {
        do {
            try await loadRecords()
        } catch {
            logError("Couldn't read downloads; not creating the session", error)
            activation = nil
            return false
        }
        await finaliseCompletedRecords()
        let session = makeSession(delegate)
        self.session = session
        isInvalidatingSession = false
        ignoredTasks.removeAll()
        startEventLoop()
        for task in await session.allTasks {
            guard let partID = task.partID, contexts[partID] != nil, tasks[partID] == nil,
                let download = task as? URLSessionDownloadTask
            else {
                ignoredTasks.insert(task.taskIdentifier)
                task.cancel()
                continue
            }
            tasks[partID] = download
            await persist {
                try await $0.setPartState(.running, partID: partID, taskIdentifier: download.taskIdentifier)
            }
            if download.state == .suspended { download.resume() }
        }
        return true
    }

    private func startEventLoop() {
        guard !isEventLoopRunning else { return }
        isEventLoopRunning = true
        let events = delegate.events
        Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    /// Lets the session's tasks finish, then creates it again (on ``sessionInvalidated()``).
    private func dropSession() {
        guard let session, !isInvalidatingSession else { return }
        isInvalidatingSession = true
        session.finishTasksAndInvalidate()
    }

    private func sessionInvalidated() {
        session = nil
        activation = nil
        isInvalidatingSession = false
        tasks.removeAll()
        ignoredTasks.removeAll()
        Task { [weak self] in await self?.recreateSession() }
    }

    private func recreateSession() async {
        guard await ensureSession() else { return }
        let deferred = deferredLaunches
        deferredLaunches.removeAll()
        for partID in deferred {
            await launch(partID)
        }
    }

    /// Adds a context for each part not yet known that hasn't completed.
    @discardableResult
    private func loadRecords() async throws -> [DownloadRecordDTO] {
        var records: [DownloadRecordDTO] = []
        for _ in 0..<3 {
            let start = epoch
            records = try await readRecords(store)
            if epoch == start { break }
        }
        for record in records {
            for part in record.parts where part.state != .completed && contexts[part.id] == nil {
                let destination = try? locations.fileURL(forRelativePath: part.destinationRelativePath)
                contexts[part.id] = PartContext(
                    recordID: record.id, connectionID: record.key.serverConnectionID, serverPath: part.serverPath,
                    destination: destination, expectedBytes: part.expectedBytes, hasResumeData: part.hasResumeData)
                delegate.setTarget(
                    destination.map { .init(destination: $0, expectedBytes: part.expectedBytes) }, for: part.id)
            }
        }
        return records
    }

    private func restartQueuedParts() async {
        for _ in 0..<3 {
            let start = epoch
            let records: [DownloadRecordDTO]
            do {
                records = try await loadRecords()
            } catch {
                logError("Couldn't read downloads", error)
                return
            }
            let candidates = records.filter { $0.state == .queued || $0.state == .downloading }
                .flatMap(\.parts).filter { $0.state != .completed }.map(\.id)
            // Once a part settles, the candidates may be stale: read them again.
            for partID in candidates where epoch == start {
                await launch(partID)
            }
            if epoch == start { return }
        }
    }

    // MARK: - Tasks

    /// Creates and resumes a task for `partID`: from its resume data while it matches the
    /// fresh request's credentials and network access, otherwise from the fresh request.
    ///
    /// - Parameter rejectedAccessToken: after a 401, the token that was rejected.
    private func launch(_ partID: UUID, rejectedAccessToken: String? = nil) async {
        guard let context = contexts[partID], tasks[partID] == nil, retries[partID] == nil, launching[partID] == nil,
            !settling.contains(partID)
        else { return }
        guard let session, !isInvalidatingSession else {
            deferredLaunches.insert(partID)
            return
        }
        guard let destination = context.destination else {
            await failPermanently(partID, code: .invalidDestination, message: "The download's destination is invalid.")
            return
        }
        let token = UUID()
        launching[partID] = token
        defer { if launching[partID] == token { launching[partID] = nil } }
        let request: URLRequest
        do {
            let credentials = try await credentials.credentials(
                for: context.connectionID, replacing: rejectedAccessToken)
            var fresh = try DownloadRequests.request(
                path: context.serverPath, configuration: credentials.configuration,
                accessToken: credentials.accessToken)
            fresh.apply(await networkAccess())
            request = fresh
        } catch {
            await retry(
                partID, code: .credentials, message: "Couldn't authorize the download: \(error.localizedDescription)")
            return
        }
        var resumeData: Data?
        if contexts[partID]?.hasResumeData == true, rejectedAccessToken == nil {
            do {
                resumeData = try vault.open(partID: partID, credentialTag: ResumeDataVault.credentialTag(for: request))
            } catch {
                logError("Couldn't read resume data", error)
                await retry(partID, code: .resumeData, message: "Couldn't read the download's resume data.")
                return
            }
            if resumeData == nil { contexts[partID]?.hasResumeData = false }
        }
        guard launching[partID] == token, self.session === session, !isInvalidatingSession, tasks[partID] == nil,
            contexts[partID] != nil, !settling.contains(partID)
        else { return }
        let task = resumeData.map(session.downloadTask(withResumeData:)) ?? session.downloadTask(with: request)
        task.taskDescription = partID.uuidString
        tasks[partID] = task
        delegate.setTarget(.init(destination: destination, expectedBytes: context.expectedBytes), for: partID)
        throttle.reset(partID)
        let started: Bool
        do {
            started = try await store.setPartState(
                .running, partID: partID, taskIdentifier: task.taskIdentifier, hasResumeData: false, now: now())
        } catch {
            logError("Couldn't update a download", error)
            started = true
        }
        guard started, tasks[partID] === task else {
            // The part completed, was deleted or was stopped meanwhile; the task never ran.
            if tasks[partID] === task { tasks[partID] = nil }
            ignoredTasks.insert(task.taskIdentifier)
            task.cancel()
            if !started { forget(partID) }
            return
        }
        // The resume data now lives in the task.
        vault.delete(partID: partID)
        contexts[partID]?.hasResumeData = false
        if resumeData == nil {
            await persist {
                try await $0.updateProgress(partID: partID, bytesWritten: 0, expectedBytes: context.expectedBytes)
            }
        }
        await persist { try await $0.setState(.downloading, forRecord: context.recordID) }
        guard tasks[partID] === task else { return }
        task.resume()
    }

    // MARK: - Events

    private func handle(_ event: DownloadSessionEvent) async {
        switch event {
        case .progress(let task, let written, let expected):
            await handleProgress(task, bytesWritten: written, expectedBytes: expected)
        case .completed(let task, let result):
            await handleCompletion(task, result)
        case .backgroundEventsFinished:
            if !backgroundWaiters.isEmpty {
                backgroundWaiters.removeFirst().resume()
            } else if !registry.consumeAbandonedWake() {
                unclaimedBackgroundFinishes += 1
            }
        case .sessionInvalidated:
            sessionInvalidated()
        case .restartQueued:
            Task { [weak self] in await self?.restartQueuedParts() }
        case .barrier(let continuation):
            continuation.resume()
        }
    }

    /// Returns once the events delivered so far are handled. For tests.
    func processPendingEvents() async {
        guard isEventLoopRunning else { return }
        await withCheckedContinuation { delegate.post(.barrier($0)) }
    }

    private func handleProgress(_ task: URLSessionTask, bytesWritten: Int64, expectedBytes: Int64) async {
        // An error body (a 401 page, say) also reports progress.
        guard let partID = task.partID, let context = contexts[partID],
            tasks[partID]?.taskIdentifier == task.taskIdentifier,
            let status = (task.response as? HTTPURLResponse)?.statusCode, status == 200 || status == 206
        else { return }
        authRetried.remove(partID)
        let expected = expectedBytes > 0 ? expectedBytes : context.expectedBytes
        let date = now()
        let decision = throttle.record(partID, bytesWritten: bytesWritten, expectedBytes: expected, at: date)
        if decision.publishes {
            progressContinuation.yield(
                DownloadProgress(
                    partID: partID, recordID: context.recordID, bytesWritten: bytesWritten, expectedBytes: expected))
        }
        if decision.persists {
            await persist {
                try await $0.updateProgress(
                    partID: partID, bytesWritten: bytesWritten, expectedBytes: expected, now: date)
            }
        }
    }

    private func handleCompletion(_ task: URLSessionTask, _ result: DownloadTaskResult) async {
        if ignoredTasks.remove(task.taskIdentifier) != nil { return }
        guard let partID = task.partID, contexts[partID] != nil else { return }
        let current = tasks[partID]
        if case .moved(let bytes) = result {
            // A finished file wins even from a stale task; drop any newer transfer.
            if let current, current.taskIdentifier != task.taskIdentifier {
                ignoredTasks.insert(current.taskIdentifier)
                current.cancel()
            }
            await complete(partID, bytes: bytes)
            return
        }
        // A stale task's failure doesn't affect the transfer that replaced it.
        guard current == nil || current?.taskIdentifier == task.taskIdentifier else { return }
        tasks[partID] = nil
        throttle.reset(partID)
        if let status = (task.response as? HTTPURLResponse)?.statusCode, status == 200 || status == 206 {
            // The server accepted the token, so a later 401 is a new one.
            authRetried.remove(partID)
        }
        switch result {
        case .moved:
            return
        case .httpStatus(401):
            await handleUnauthorized(partID, task: task)
        case .httpStatus(let status) where status == 0 || status == 408 || status == 429 || status >= 500:
            await retry(partID, code: .transfer, message: "The server returned HTTP \(status).")
        case .httpStatus(let status):
            await failPermanently(partID, code: .httpStatus, message: "The server returned HTTP \(status).")
        case .redirectedUnauthorized:
            await failPermanently(
                partID, code: .redirectedUnauthorized,
                message: "The download was redirected, and its sign-in isn't sent to the new address.")
        case .offOrigin:
            await failPermanently(partID, code: .offOrigin, message: "The download was redirected to another server.")
        case .unexpectedContent(let type):
            await retry(partID, code: .unexpectedContent, message: "The server sent \(type) instead of the file.")
        case .sizeMismatch(let expected, let actual):
            await retry(partID, code: .sizeMismatch, message: "The file has \(actual) bytes instead of \(expected).")
        case .moveFailed(let message, let isOutOfSpace):
            if isOutOfSpace {
                await failPermanently(partID, code: .outOfSpace, message: message)
            } else {
                await retry(partID, code: .fileSystem, message: message)
            }
        case .failed(let failure):
            await handleTransferFailure(partID, task: task, failure)
        }
    }

    private func handleTransferFailure(
        _ partID: UUID, task: URLSessionTask, _ failure: DownloadTransferFailure
    ) async {
        if let data = failure.resumeData {
            contexts[partID]?.hasResumeData = seal(data, partID: partID, task: task)
        }
        if failure.isOutOfSpace {
            await failPermanently(partID, code: .outOfSpace, message: failure.message)
            return
        }
        guard failure.isBackgroundCancellation || failure.isSessionLost else {
            await retry(partID, code: .transfer, message: failure.message)
            return
        }
        // Not the transfer's fault: queue it again without counting a failure.
        let hasResumeData = contexts[partID]?.hasResumeData
        await persist {
            try await $0.setPartState(.queued, partID: partID, taskIdentifier: nil, hasResumeData: hasResumeData)
        }
        if failure.isSessionLost {
            deferredLaunches.insert(partID)
            dropSession()
        } else if restartsQueuedParts {
            Task { [weak self] in await self?.launch(partID) }
        }
    }

    /// Resume data replays the rejected header, so it is deleted. A 401 for the current token
    /// recreates the task from a fresh request once; a 401 for a token that has since been
    /// replaced doesn't count.
    private func handleUnauthorized(_ partID: UUID, task: URLSessionTask) async {
        guard let context = contexts[partID] else { return }
        vault.delete(partID: partID)
        contexts[partID]?.hasResumeData = false
        let message = "The server rejected the download's sign-in (HTTP 401)."
        let header = task.originalRequest?.value(forHTTPHeaderField: "Authorization") ?? ""
        let rejected = header.hasPrefix("Bearer ") ? String(header.dropFirst("Bearer ".count)) : header
        let current = await credentials.currentCredentials(for: context.connectionID)?.accessToken
        let isStale = current != nil && current != rejected
        if !isStale, !authRetried.insert(partID).inserted {
            await failPermanently(partID, code: .unauthorized, message: message)
            return
        }
        await persist {
            try await $0.setPartState(
                .queued, partID: partID, taskIdentifier: nil, error: message, hasResumeData: false)
        }
        Task { [weak self] in await self?.launch(partID, rejectedAccessToken: rejected) }
    }

    /// Records the moved file's size, then finalises the record once every part completed.
    private func complete(_ partID: UUID, bytes: Int64) async {
        guard let context = contexts[partID], settling.insert(partID).inserted else { return }
        tasks[partID] = nil
        retries.removeValue(forKey: partID)?.cancel()
        vault.delete(partID: partID)
        let completed: Bool
        do {
            completed = try await store.completePart(partID: partID, finalBytes: bytes, now: now())
        } catch {
            logError("Couldn't record a finished download", error)
            completed = false
        }
        forget(partID)
        settling.remove(partID)
        epoch += 1
        guard completed else { return }
        updateContinuation.yield(.partCompleted(partID: partID, recordID: context.recordID))
        if let record = try? await store.record(id: context.recordID), record.isComplete {
            await finalise(record)
        }
    }

    /// Makes a complete record a local item, then deletes it. A failure is logged; the next
    /// activation repeats it.
    private func finalise(_ record: DownloadRecordDTO) async {
        do {
            let item = try await localItems.upsertFromDownload(record, now: now())
            try await store.deleteRecord(record.id)
            updateContinuation.yield(.recordComplete(recordID: record.id, itemID: item.id))
        } catch {
            logError("Couldn't finalise a download", error)
        }
    }

    private func finaliseCompletedRecords() async {
        do {
            for record in try await store.completedRecords() {
                await finalise(record)
            }
        } catch {
            logError("Couldn't read finished downloads", error)
        }
    }

    /// Marks the part failed and schedules a retry, or fails it for good once the retries
    /// are used up.
    private func retry(_ partID: UUID, code: DownloadFailureCode, message: String) async {
        guard let context = contexts[partID] else { return }
        let failure = failures[partID, default: 0] + 1
        failures[partID] = failure
        guard let delay = retryPolicy.delay(beforeRetry: failure, random: random()) else {
            await failPermanently(partID, code: code, message: message)
            return
        }
        await persist {
            try await $0.setPartState(
                .failed, partID: partID, taskIdentifier: nil, error: message, hasResumeData: context.hasResumeData)
        }
        updateContinuation.yield(
            .partFailed(partID: partID, recordID: context.recordID, code: code, message: message, willRetry: true))
        let clock = clock
        retries[partID] = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            await self?.retryNow(partID)
        }
    }

    private func retryNow(_ partID: UUID) async {
        guard !Task.isCancelled, retries.removeValue(forKey: partID) != nil else { return }
        await launch(partID)
    }

    /// Fails the part and its record for good, and stops the record's other parts, keeping
    /// their resume data, so a retry of the record continues them.
    private func failPermanently(_ partID: UUID, code: DownloadFailureCode, message: String) async {
        guard let context = contexts[partID], settling.insert(partID).inserted else { return }
        tasks[partID] = nil
        retries.removeValue(forKey: partID)?.cancel()
        await persist {
            try await $0.setPartState(
                .failed, partID: partID, taskIdentifier: nil, error: message, hasResumeData: context.hasResumeData)
        }
        let siblings = contexts.filter { $0.value.recordID == context.recordID && $0.key != partID }.map(\.key)
        await stop(partIDs: siblings, keepingResumeData: true)
        await persist { try await $0.setState(.failed, forRecord: context.recordID) }
        forget(partID)
        settling.remove(partID)
        epoch += 1
        updateContinuation.yield(
            .partFailed(partID: partID, recordID: context.recordID, code: code, message: message, willRetry: false))
    }

    // MARK: - Helpers

    /// Drops what the engine knows about `partID` until the store is read again.
    private func forget(_ partID: UUID) {
        contexts[partID] = nil
        tasks[partID] = nil
        retries.removeValue(forKey: partID)?.cancel()
        failures[partID] = nil
        authRetried.remove(partID)
        deferredLaunches.remove(partID)
        throttle.reset(partID)
        delegate.setTarget(nil, for: partID)
    }

    /// Seals `data` under the task's request; returns whether it was kept.
    private func seal(_ data: Data, partID: UUID, task: URLSessionTask) -> Bool {
        do {
            try vault.seal(
                data, partID: partID, credentialTag: ResumeDataVault.credentialTag(for: task.originalRequest))
            return true
        } catch {
            logError("Couldn't seal resume data", error)
            vault.delete(partID: partID)
            return false
        }
    }

    /// Runs a store write, logging failures: the engine keeps transferring when one fails.
    private func persist(_ write: (DownloadStore) async throws -> Void) async {
        do {
            try await write(store)
        } catch {
            logError("Couldn't update a download", error)
        }
    }

    private func logError(_ message: String, _ error: any Error) {
        Log.downloads.error(
            "\(message, privacy: .public): \(Log.redact(String(describing: error)), privacy: .public)")
    }
}
