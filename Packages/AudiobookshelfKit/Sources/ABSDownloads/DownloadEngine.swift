import ABSAPI
import ABSCore
import ABSData
import Foundation
import OSLog
import Synchronization

/// A change the engine reports; the UI reads live progress from here, and ``DownloadStore``
/// holds the durable state.
public enum DownloadUpdate: Sendable, Equatable {
    case progress(partID: UUID, bytesWritten: Int64, expectedBytes: Int64)
    case partCompleted(partID: UUID, recordID: UUID)
    /// `willRetry` is `false` when the part failed for good and its record is now `failed`.
    case partFailed(partID: UUID, recordID: UUID, message: String, willRetry: Bool)
    /// Every part of the record has completed; it is ready to become a local item.
    case recordComplete(recordID: UUID)
}

/// Downloads the parts of ``DownloadStore`` records with one background `URLSession` task
/// per part (#72).
///
/// - Each task's `taskDescription` is its part ID, which is how tasks are matched to parts
///   after a relaunch; the store's `taskIdentifier` is only a cache.
/// - Requests carry `Authorization: Bearer` and the custom headers, never `?token=`. The
///   access token is refreshed before each task is created; after a 401 the task is
///   recreated once from a fresh request.
/// - Resume data from failed transfers is sealed in a ``ResumeDataVault`` and only used while
///   the credentials it was created with are current (ADR 0007).
/// - Failures are retried with ``RetryPolicy`` backoff; progress is written to the store at
///   most every 2 seconds per part and on every state change.
///
/// Finalising a complete record (making it a local item and deleting the record) is up to
/// the caller, on ``DownloadUpdate/recordComplete(recordID:)``. Create one engine per process:
/// a background session identifier may only be used by one session at a time.
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

    /// The engine's updates, for one consumer. Only the newest are kept if it falls behind.
    public nonisolated let updates: AsyncStream<DownloadUpdate>
    private let updateContinuation: AsyncStream<DownloadUpdate>.Continuation
    private let store: DownloadStore
    private let credentials: any DownloadCredentialProviding
    private let vault: ResumeDataVault
    private let locations: DownloadLocations
    private let retryPolicy: RetryPolicy
    private let networkAccess: @Sendable () async -> NetworkAccess
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    private let makeSession: DownloadSessionFactory
    private let delegate = DownloadSessionDelegate()

    private var activation: Task<Void, Never>?
    private var session: (any DownloadSession)?
    private var contexts: [UUID: PartContext] = [:]
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var launching: Set<UUID> = []
    private var retries: [UUID: Task<Void, Never>] = [:]
    private var failures: [UUID: Int] = [:]
    private var authRetried: Set<UUID> = []
    /// Tasks the engine cancelled or doesn't own, whose completion is ignored.
    private var ignoredTasks: Set<Int> = []
    private var lastProgressWrite: [UUID: Date] = [:]
    private var backgroundWaiters: [CheckedContinuation<Void, Never>] = []
    private var backgroundEventsPending = false

    private static let progressWriteInterval: TimeInterval = 2
    private static let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "downloads")

    /// - Parameters:
    ///   - networkAccess: the request flags for the current download cellular policy, read
    ///     when each task is created.
    ///   - makeSession: ``backgroundSession(sharedContainerIdentifier:)`` in the app.
    public init(
        store: DownloadStore,
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
        (updates, updateContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(500))
        self.store = store
        self.credentials = credentials
        self.vault = vault
        self.locations = locations
        self.retryPolicy = retryPolicy
        self.networkAccess = networkAccess
        self.clock = clock
        self.now = now
        self.random = random
        self.makeSession = makeSession
    }

    // MARK: - Public API

    /// Creates the session, reattaches to the transfers that survived a relaunch and restarts
    /// parts of `queued` and `downloading` records that have no transfer. Idempotent.
    public func activate() async {
        if activation == nil {
            activation = Task { await performActivation() }
        }
        await activation?.value
    }

    /// Starts (or restarts) the given parts; parts that are already transferring are left
    /// alone. Retry counts start over.
    public func start(partIDs: [UUID]) async {
        await activate()
        await loadRecords()
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
            launching.remove(partID)
            var hasResumeData = keepingResumeData && contexts[partID]?.hasResumeData == true
            if let task = tasks.removeValue(forKey: partID) {
                ignoredTasks.insert(task.taskIdentifier)
                if keepingResumeData, let data = await task.cancelByProducingResumeData() {
                    hasResumeData = seal(data, partID: partID, task: task)
                } else {
                    task.cancel()
                }
            }
            if !keepingResumeData { vault.delete(partID: partID) }
            contexts[partID]?.hasResumeData = hasResumeData
            await persist {
                try await $0.setPartState(.queued, partID: partID, taskIdentifier: nil, hasResumeData: hasResumeData)
            }
        }
    }

    /// Deletes the resume data of every part of `connectionID`'s downloads, for sign-out,
    /// removal or a credential change (ADR 0003). Their next start is a fresh request.
    public func discardResumeData(connectionID: UUID) async {
        let records = (try? await store.records(serverConnectionID: connectionID)) ?? []
        for part in records.flatMap(\.parts) where part.hasResumeData || contexts[part.id]?.hasResumeData == true {
            vault.delete(partID: part.id)
            contexts[part.id]?.hasResumeData = false
            await persist {
                try await $0.setPartState(
                    part.state, partID: part.id, taskIdentifier: part.taskIdentifier, error: part.lastError,
                    hasResumeData: false)
            }
        }
    }

    /// Call from `.backgroundTask(.urlSession(DownloadEngine.sessionIdentifier))`: makes sure
    /// the session exists, then returns once it has delivered and the engine has handled
    /// the events that relaunched the app.
    public func handleBackgroundEvents() async {
        await activate()
        if backgroundEventsPending {
            backgroundEventsPending = false
            return
        }
        await withCheckedContinuation { backgroundWaiters.append($0) }
    }

    private struct WeakEngine: Sendable {
        weak var engine: DownloadEngine?
    }

    private static let active = Mutex(WeakEngine())

    /// ``handleBackgroundEvents()`` on the activated engine. Returns at once when there is
    /// none: the events stay queued until an engine creates the session.
    public static func handleBackgroundEvents() async {
        guard let engine = active.withLock({ $0.engine }) else { return }
        await engine.handleBackgroundEvents()
    }

    // MARK: - Activation

    private func performActivation() async {
        Self.active.withLock { $0.engine = self }
        let records = await loadRecords()
        let session = makeSession(delegate)
        self.session = session
        let events = delegate.events
        Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
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
        let candidates = records.filter { $0.state == .queued || $0.state == .downloading }
            .flatMap(\.parts).filter { $0.state != .completed }.map(\.id)
        delegate.post(.reattached(candidates: candidates))
    }

    /// Adds a context for each part not yet known that hasn't completed.
    @discardableResult
    private func loadRecords() async -> [DownloadRecordDTO] {
        let records: [DownloadRecordDTO]
        do {
            records = try await store.allRecords()
        } catch {
            Self.logger.error("Couldn't read downloads: \(error, privacy: .public)")
            return []
        }
        for record in records {
            for part in record.parts where part.state != .completed && contexts[part.id] == nil {
                let destination = try? locations.fileURL(forRelativePath: part.destinationRelativePath)
                contexts[part.id] = PartContext(
                    recordID: record.id, connectionID: record.key.serverConnectionID, serverPath: part.serverPath,
                    destination: destination, expectedBytes: part.expectedBytes, hasResumeData: part.hasResumeData)
                delegate.setDestination(destination, for: part.id)
            }
        }
        return records
    }

    // MARK: - Tasks

    /// Creates and resumes a task for `partID`: from its resume data while the credentials
    /// still match, otherwise from a fresh request.
    ///
    /// - Parameter rejectedAccessToken: after a 401, the token that was rejected.
    private func launch(_ partID: UUID, rejectedAccessToken: String? = nil) async {
        guard let context = contexts[partID], let session, tasks[partID] == nil, retries[partID] == nil,
            launching.insert(partID).inserted
        else { return }
        defer { launching.remove(partID) }
        guard context.destination != nil else {
            await failPermanently(partID, message: "The download's destination is invalid.")
            return
        }
        var task: URLSessionDownloadTask?
        if context.hasResumeData {
            if rejectedAccessToken == nil,
                let current = await credentials.currentCredentials(for: context.connectionID),
                let request = try? DownloadRequests.request(
                    path: context.serverPath, configuration: current.configuration, accessToken: current.accessToken),
                let data = vault.open(partID: partID, credentialTag: ResumeDataVault.credentialTag(for: request))
            {
                task = session.downloadTask(withResumeData: data)
            }
            vault.delete(partID: partID)
            contexts[partID]?.hasResumeData = false
        }
        if task == nil {
            do {
                let credentials = try await credentials.credentials(
                    for: context.connectionID, replacing: rejectedAccessToken)
                var request = try DownloadRequests.request(
                    path: context.serverPath, configuration: credentials.configuration,
                    accessToken: credentials.accessToken)
                request.apply(await networkAccess())
                guard launching.contains(partID) else { return }
                task = session.downloadTask(with: request)
                await persist {
                    try await $0.updateProgress(partID: partID, bytesWritten: 0, expectedBytes: context.expectedBytes)
                }
            } catch {
                await retry(partID, message: "Couldn't authorize the download: \(error.localizedDescription)")
                return
            }
        }
        guard let task, launching.contains(partID), tasks[partID] == nil else {
            task?.cancel()
            return
        }
        task.taskDescription = partID.uuidString
        tasks[partID] = task
        let started = try? await store.setPartState(
            .running, partID: partID, taskIdentifier: task.taskIdentifier, hasResumeData: false, now: now())
        guard started != false else {
            // The part completed or was deleted meanwhile.
            tasks[partID] = nil
            contexts[partID] = nil
            ignoredTasks.insert(task.taskIdentifier)
            task.cancel()
            return
        }
        await persist { try await $0.setState(.downloading, forRecord: context.recordID) }
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
            if backgroundWaiters.isEmpty { backgroundEventsPending = true }
            for waiter in backgroundWaiters { waiter.resume() }
            backgroundWaiters.removeAll()
        case .reattached(let candidates):
            for partID in candidates { await launch(partID) }
        }
    }

    private func handleProgress(_ task: URLSessionTask, bytesWritten: Int64, expectedBytes: Int64) async {
        guard let partID = task.partID, let context = contexts[partID],
            tasks[partID]?.taskIdentifier == task.taskIdentifier
        else { return }
        let expected = expectedBytes > 0 ? expectedBytes : context.expectedBytes
        updateContinuation.yield(.progress(partID: partID, bytesWritten: bytesWritten, expectedBytes: expected))
        let date = now()
        if let last = lastProgressWrite[partID], date.timeIntervalSince(last) < Self.progressWriteInterval { return }
        lastProgressWrite[partID] = date
        await persist {
            try await $0.updateProgress(partID: partID, bytesWritten: bytesWritten, expectedBytes: expected, now: date)
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
        switch result {
        case .moved:
            return
        case .httpStatus(401):
            await handleUnauthorized(partID, task: task)
        case .httpStatus(let status) where status == 408 || status == 429 || status >= 500:
            await retry(partID, message: "The server returned HTTP \(status).")
        case .httpStatus(let status):
            await failPermanently(partID, message: "The server returned HTTP \(status).")
        case .offOrigin:
            await failPermanently(partID, message: "The download was redirected to another server.")
        case .moveFailed(let message):
            await retry(partID, message: message)
        case .failed(let failure):
            if let data = failure.resumeData {
                contexts[partID]?.hasResumeData = seal(data, partID: partID, task: task)
            }
            if failure.isForceQuit {
                // Force-quitting cancels transfers; restart without counting a failure.
                let hasResumeData = contexts[partID]?.hasResumeData
                await persist {
                    try await $0.setPartState(
                        .queued, partID: partID, taskIdentifier: nil, hasResumeData: hasResumeData)
                }
                await launch(partID)
            } else {
                await retry(partID, message: failure.message)
            }
        }
    }

    /// Resume data replays the rejected header, so it is deleted; the task is recreated from
    /// a fresh request once.
    private func handleUnauthorized(_ partID: UUID, task: URLSessionTask) async {
        vault.delete(partID: partID)
        contexts[partID]?.hasResumeData = false
        let message = "The server rejected the download's sign-in (HTTP 401)."
        guard authRetried.insert(partID).inserted else {
            await failPermanently(partID, message: message)
            return
        }
        await persist {
            try await $0.setPartState(
                .queued, partID: partID, taskIdentifier: nil, error: message, hasResumeData: false)
        }
        let header = task.originalRequest?.value(forHTTPHeaderField: "Authorization") ?? ""
        let token = header.hasPrefix("Bearer ") ? String(header.dropFirst("Bearer ".count)) : header
        await launch(partID, rejectedAccessToken: token)
    }

    private func complete(_ partID: UUID, bytes: Int64) async {
        guard let context = contexts.removeValue(forKey: partID) else { return }
        tasks[partID] = nil
        retries.removeValue(forKey: partID)?.cancel()
        failures[partID] = nil
        authRetried.remove(partID)
        lastProgressWrite[partID] = nil
        delegate.setDestination(nil, for: partID)
        vault.delete(partID: partID)
        let date = now()
        await persist {
            try await $0.updateProgress(partID: partID, bytesWritten: bytes, expectedBytes: bytes, now: date)
        }
        await persist {
            try await $0.setPartState(
                .completed, partID: partID, taskIdentifier: nil, error: nil, hasResumeData: false, now: date)
        }
        updateContinuation.yield(.partCompleted(partID: partID, recordID: context.recordID))
        if (try? await store.record(id: context.recordID))?.isComplete == true {
            updateContinuation.yield(.recordComplete(recordID: context.recordID))
        }
    }

    /// Marks the part failed and schedules a retry, or fails it for good once the retries
    /// are used up.
    private func retry(_ partID: UUID, message: String) async {
        guard let context = contexts[partID] else { return }
        let failure = failures[partID, default: 0] + 1
        failures[partID] = failure
        guard let delay = retryPolicy.delay(beforeRetry: failure, random: random()) else {
            await failPermanently(partID, message: message)
            return
        }
        await persist {
            try await $0.setPartState(
                .failed, partID: partID, taskIdentifier: nil, error: message, hasResumeData: context.hasResumeData)
        }
        updateContinuation.yield(
            .partFailed(partID: partID, recordID: context.recordID, message: message, willRetry: true))
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

    private func failPermanently(_ partID: UUID, message: String) async {
        guard let context = contexts.removeValue(forKey: partID) else { return }
        failures[partID] = nil
        authRetried.remove(partID)
        delegate.setDestination(nil, for: partID)
        await persist {
            try await $0.setPartState(
                .failed, partID: partID, taskIdentifier: nil, error: message, hasResumeData: context.hasResumeData)
        }
        await persist { try await $0.setState(.failed, forRecord: context.recordID) }
        updateContinuation.yield(
            .partFailed(partID: partID, recordID: context.recordID, message: message, willRetry: false))
    }

    // MARK: - Helpers

    /// Seals `data` under the credentials of the task's request; returns whether it was kept.
    private func seal(_ data: Data, partID: UUID, task: URLSessionTask) -> Bool {
        do {
            try vault.seal(
                data, partID: partID, credentialTag: ResumeDataVault.credentialTag(for: task.originalRequest))
            return true
        } catch {
            Self.logger.error("Couldn't seal resume data: \(error, privacy: .public)")
            vault.delete(partID: partID)
            return false
        }
    }

    /// Runs a store write, logging failures: the engine keeps transferring when one fails.
    private func persist(_ write: (DownloadStore) async throws -> Void) async {
        do {
            try await write(store)
        } catch {
            Self.logger.error("Couldn't update a download: \(error, privacy: .public)")
        }
    }
}
