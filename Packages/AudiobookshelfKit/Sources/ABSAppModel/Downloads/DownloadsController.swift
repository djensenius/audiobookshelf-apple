import ABSCore
import ABSData
import ABSDownloads
import Foundation
import Observation

/// Starts downloads under the user's download cellular policy and publishes the downloads under
/// way for the UI. Ports the legacy `mixins/cellularPermissionHelpers.js` check for downloads.
///
/// - ``request(item:episodeID:connectionID:)`` checks ``NetworkPolicy/canDownload(waitingUpTo:)``
///   first: on a metered path, ``CellularPolicy/ask`` returns
///   ``DownloadRequestOutcome/needsConfirmation(_:_:)`` and ``CellularPolicy/never`` returns
///   ``DownloadRequestOutcome/denied(_:)``, without queueing anything. After the user agrees,
///   ``confirmMeteredDownload(item:episodeID:ticket:)`` queues it, as the legacy confirm
///   dialog did. Once approved, the download keeps going on the metered path.
/// - A request belongs to the account session running when it's made (``DownloadRequestSessions``),
///   and its metered confirmation to the same one (``DownloadRequestTicket``): without one for
///   the connection, or if its user may not download (`permissions.download`), it returns
///   ``DownloadRequestOutcome/rejected(_:)``. Checked again after the path wait, whatever the path,
///   and before the record is saved. If that session ends meanwhile, or a sign-out, expiry or
///   removal stops the connection's downloads before its record is queued
///   (``DownloadManager/quiesceGeneration()``), nothing is queued and it returns
///   ``DownloadRequestError/sessionEnded``. A switch away that comes later still saves the
///   record; a switch keeps the connection's downloads running anyway.
/// - Under ``CellularPolicy/ask``, transfers the user didn't start now aren't asked about: the
///   engine's retries, resumes at relaunch, restarts, and new tasks after a path change all run
///   with the flags ``CellularPolicy/ask`` allows. A resume or retry the user starts (#75) must go
///   through the same check as ``request(item:episodeID:connectionID:)`` (``gate(waitingForPath:)``).
/// - ``records`` and ``progress`` follow ``DownloadManager/events()`` from ``start()`` on, on top
///   of the records stored when it ran. A completed, cancelled or removed record leaves both.
///   Cover-only records (``DownloadRecordDTO/isCoverOnly``), which fetch a podcast's cover
///   again, are left out of both.
/// - While ``AppSettings/downloadUsingCellular`` is ``CellularPolicy/never``, transfers that may
///   have been given metered access (``networkAccess`` handed out cellular or Low Data Mode flags
///   since the last restart, or before the controller existed) restart under the new flags
///   (``DownloadManager/restartActiveTransfers()``): a running task keeps the network access it was
///   created with. A restart that fails is tried again at the next policy change or ``start()``.
///   ``CellularPolicy/always`` and ``CellularPolicy/ask`` allow every network, so a change between
///   them, or away from ``CellularPolicy/never``, keeps transfers running.
/// - Failed downloads aren't retried here; the user retries them.
///
/// Build one ``DownloadNetworkAccess`` on ``AppSettings/defaults`` and pass it to both the engine
/// (its ``DownloadNetworkAccess/provider``) and this controller.
@MainActor
@Observable
public final class DownloadsController {
    /// A record's live progress across all its parts, as ``DownloadManagerEvent/progress(recordID:fraction:bytes:)``
    /// reports it.
    public struct Progress: Sendable, Equatable {
        /// From 0 to 1; 0 while no size is known.
        public var fraction: Double
        public var bytes: Int64

        public init(fraction: Double, bytes: Int64) {
            self.fraction = fraction
            self.bytes = bytes
        }
    }

    /// The download records that haven't completed, oldest first.
    public private(set) var records: [DownloadRecordDTO] = []
    /// The latest progress of each record in ``records`` that reported any, by record ID.
    public private(set) var progress: [UUID: Progress] = [:]
    /// Why the stored records couldn't be read at ``start()`` (after one retry), or `nil`. Records
    /// still appear as their events arrive, and ``DownloadsTabModel/reload()`` reads them again.
    public private(set) var loadError: (any Error)?

    /// The network access flags for new download tasks, shared with the engine.
    public nonisolated let networkAccess: DownloadNetworkAccess

    @ObservationIgnored private let manager: any DownloadManaging
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let policy: NetworkPolicy
    @ObservationIgnored private let storedRecords: @Sendable () async throws -> [DownloadRecordDTO]
    @ObservationIgnored private let pathTimeout: Duration
    @ObservationIgnored private let sessions: @MainActor (UUID) -> DownloadRequestSession?
    /// The first ``start()``'s work; later calls wait for it.
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// Records that events changed or removed while the stored records were read, so the read
    /// doesn't bring back an older copy or a removed record; `nil` outside that read.
    @ObservationIgnored private var changedWhileLoading: Set<UUID>?

    /// Test hooks: called after an event, or a download cellular policy change, was handled.
    @ObservationIgnored var eventHandled: (@MainActor (DownloadManagerEvent) -> Void)?
    @ObservationIgnored var policyHandled: (@MainActor (CellularPolicy) -> Void)?

    /// - Parameters:
    ///   - manager: the app's ``DownloadManager``.
    ///   - monitor: the network path to check requests against.
    ///   - settings: the download cellular policy.
    ///   - networkAccess: the instance the engine reads its flags from, built on
    ///     `settings.defaults`; its ``DownloadNetworkAccess/treatsExpensiveAsCellular`` also applies
    ///     to requests.
    ///   - storedRecords: the records stored when ``start()`` runs, for example
    ///     `DownloadStore.allRecords()`.
    ///   - sessions: the running session of a connection, or `nil`, for example
    ///     ``DownloadRequestSessions/session(for:)``.
    ///   - pathTimeout: how long a request waits for the first network path before it is allowed.
    public init(
        manager: any DownloadManaging,
        monitor: NetworkMonitor,
        settings: AppSettings,
        networkAccess: DownloadNetworkAccess,
        storedRecords: @escaping @Sendable () async throws -> [DownloadRecordDTO],
        sessions: @escaping @MainActor (UUID) -> DownloadRequestSession?,
        pathTimeout: Duration = .milliseconds(500)
    ) {
        self.manager = manager
        self.sessions = sessions
        self.settings = settings
        self.networkAccess = networkAccess
        policy = NetworkPolicy(
            monitor: monitor, settings: settings,
            treatsExpensiveAsCellular: networkAccess.treatsExpensiveAsCellular)
        self.storedRecords = storedRecords
        self.pathTimeout = pathTimeout
    }

    isolated deinit {
        for task in tasks { task.cancel() }
    }

    // MARK: - Lifecycle

    /// Subscribes to the manager's events, reads the stored records, and starts watching the
    /// download cellular policy. Later calls wait for the first one to finish, then try again a
    /// restart for ``CellularPolicy/never`` that failed.
    public func start() async {
        if let startup {
            await startup.value
            await apply(settings.downloadUsingCellular)
            return
        }
        let startup = Task { await self.run() }
        self.startup = startup
        await startup.value
    }

    private func run() async {
        let settings = settings
        tasks.append(
            Task { [weak self] in
                let changes = Observations { @MainActor in settings.downloadUsingCellular }
                for await policy in changes {
                    guard let self else { return }
                    await self.apply(policy)
                    self.policyHandled?(policy)
                }
            })
        // Subscribed before the read, so nothing that happens after it is missed.
        let events = await manager.events()
        tasks.append(
            Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    self.handle(event)
                }
            })
        await loadStoredRecords()
    }

    /// Reads the stored records again if ``start()`` couldn't (``loadError``), as it does: a
    /// record that events changed or removed meanwhile keeps its newer state. Does nothing once a
    /// read succeeded, or while one is under way. For the Downloads tab's refresh (#75).
    func retryLoadingStoredRecords() async {
        guard loadError != nil, changedWhileLoading == nil else { return }
        await loadStoredRecords()
    }

    /// Lists the stored records, except those events changed or removed during the read.
    private func loadStoredRecords() async {
        changedWhileLoading = []
        defer { changedWhileLoading = nil }
        if let stored = await readStoredRecords() {
            let changed = changedWhileLoading ?? []
            for record in stored where !changed.contains(record.id) {
                upsert(record)
            }
        }
        // Progress that arrived meanwhile for a record that isn't listed.
        let listed = Set(records.map(\.id))
        progress = progress.filter { listed.contains($0.key) }
    }

    /// The stored records, read once more if the first read fails; `nil`, with ``loadError`` set,
    /// if both fail.
    private func readStoredRecords() async -> [DownloadRecordDTO]? {
        var lastError: (any Error)?
        for _ in 0..<2 {
            do {
                let stored = try await storedRecords()
                loadError = nil
                return stored
            } catch {
                lastError = error
            }
        }
        loadError = lastError
        if let lastError {
            Log.downloads.error(
                "Couldn't read the stored downloads: \(Log.redact(String(describing: lastError)), privacy: .public)")
        }
        return nil
    }

    // MARK: - Requests

    /// Queues the download of a book, or of one podcast episode, if the download cellular policy
    /// allows it on the current path (waiting up to the path timeout for the first path).
    ///
    /// - Parameter item: an expanded item (`ItemEndpoints.item(id:)`) of the server `connectionID`.
    public func request(item: LibraryItem, episodeID: String?, connectionID: UUID) async -> DownloadRequestOutcome {
        let ticket: DownloadRequestTicket
        switch await begin(connectionID: connectionID) {
        case .success(let begun): ticket = begun
        case .failure(let error): return .rejected(error)
        }
        let decision = await gate(waitingForPath: true)
        // The path wait may have outlasted the session or the permission: a stale request is
        // dropped, whatever the path, rather than prompting.
        if let error = check(ticket) { return .rejected(error) }
        return switch decision {
        case .allowed: await enqueue(item: item, episodeID: episodeID, ticket: ticket)
        case .askUser(let reason): .needsConfirmation(reason, ticket)
        case .denied(let reason): .denied(reason)
        }
    }

    /// Queues a download the user agreed to after
    /// ``DownloadRequestOutcome/needsConfirmation(_:_:)``, in the session of the request that
    /// asked (`ticket`): rejected once that session has ended. Denied instead if the policy became
    /// ``CellularPolicy/never`` while they decided.
    public func confirmMeteredDownload(
        item: LibraryItem, episodeID: String?, ticket: DownloadRequestTicket
    ) async -> DownloadRequestOutcome {
        if let error = check(ticket) { return .rejected(error) }
        if case .denied(let reason) = await gate(waitingForPath: false) { return .denied(reason) }
        return await enqueue(item: item, episodeID: episodeID, ticket: ticket)
    }

    /// Whether a request for `connectionID` would be let through now: one of its sessions is
    /// running and its user may download. Screens show their download actions by it.
    public func canRequest(connectionID: UUID) -> Bool {
        sessions(connectionID)?.canDownload == true
    }

    /// Whether a download the user starts may go ahead on the current path under the download
    /// cellular policy. With `waitingForPath`, waits up to the path timeout for the first path.
    /// For requests here, and for the user's resume and retry (#75).
    func gate(waitingForPath: Bool) async -> NetworkDecision {
        waitingForPath ? await policy.canDownload(waitingUpTo: pathTimeout) : policy.canDownload()
    }

    /// The ticket of a request made now: the session running for `connectionID`, taken before
    /// anything is awaited, and the manager's generation, taken next. The session is checked again
    /// once the generation is known, so a session that ended meanwhile (a switch away and back,
    /// which doesn't quiesce) isn't swapped for the next one; a quiesce that began after the
    /// generation is caught when the record is saved.
    private func begin(connectionID: UUID) async -> Result<DownloadRequestTicket, DownloadRequestError> {
        guard let session = sessions(connectionID) else { return .failure(.sessionEnded) }
        guard session.canDownload else { return .failure(.notPermitted) }
        let generation = await manager.quiesceGeneration()
        let ticket = DownloadRequestTicket(
            connectionID: connectionID, sessionID: session.sessionID, generation: generation)
        if let error = check(ticket) { return .failure(error) }
        return .success(ticket)
    }

    /// Why `ticket`'s request may not go ahead now: its session ended, or its user may no
    /// longer download; `nil` if it may.
    private func check(_ ticket: DownloadRequestTicket) -> DownloadRequestError? {
        guard let session = sessions(ticket.connectionID), session.sessionID == ticket.sessionID else {
            return .sessionEnded
        }
        return session.canDownload ? nil : .notPermitted
    }

    private func enqueue(
        item: LibraryItem, episodeID: String?, ticket: DownloadRequestTicket
    ) async -> DownloadRequestOutcome {
        // The user's decision may have outlasted the session or the permission.
        if let error = check(ticket) { return .rejected(error) }
        do {
            return .started(
                try await manager.enqueue(
                    item: item, episodeID: episodeID, connectionID: ticket.connectionID, replacingExisting: false,
                    unlessQuiescedSince: ticket.generation))
        } catch {
            if case .downloadsStopped = error { return .rejected(.sessionEnded) }
            return .failed(error)
        }
    }

    // MARK: - Policy

    /// Under ``CellularPolicy/never``, restarts the transfers under way if metered access was handed
    /// out since the last restart. A failed restart is tried again next time.
    private func apply(_ policy: CellularPolicy) async {
        guard policy == .never, networkAccess.takeHandedOutMetered() else { return }
        do {
            try await manager.restartActiveTransfers()
        } catch {
            networkAccess.markHandedOutMetered()
            Log.downloads.error(
                "Couldn't restart downloads for a stricter cellular policy: \(Log.redact(String(describing: error)), privacy: .public)"
            )
        }
    }

    // MARK: - Events

    private func handle(_ event: DownloadManagerEvent) {
        switch event {
        case .recordChanged(let record):
            changedWhileLoading?.insert(record.id)
            upsert(record)
        case .progress(let recordID, let fraction, let bytes):
            // A late event of a removed record isn't kept; while loading, its record may follow.
            if changedWhileLoading != nil || records.contains(where: { $0.id == recordID }) {
                progress[recordID] = Progress(fraction: fraction, bytes: bytes)
            }
        case .completed(let recordID, _, _), .recordRemoved(let recordID):
            changedWhileLoading?.insert(recordID)
            records.removeAll { $0.id == recordID }
            progress[recordID] = nil
        case .failed:
            // Its record's change is reported with `recordChanged`; the user retries it.
            break
        }
        eventHandled?(event)
    }

    private func upsert(_ record: DownloadRecordDTO) {
        // A cover-only record restores a podcast's cover (#326); it isn't a download the user
        // started, so it isn't listed, and its progress is dropped.
        guard !record.isCoverOnly else { return }
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            let index = records.firstIndex { $0.createdAt > record.createdAt } ?? records.endIndex
            records.insert(record, at: index)
        }
    }
}

// In this file: the protocol's `Sendable` conformance must be declared with the class.
extension DownloadsController: DownloadRequesting {}
