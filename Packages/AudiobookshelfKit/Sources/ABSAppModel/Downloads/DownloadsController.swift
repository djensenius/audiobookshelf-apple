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
///   ``DownloadRequestOutcome/needsConfirmation(_:)`` and ``CellularPolicy/never`` returns
///   ``DownloadRequestOutcome/denied(_:)``, without queueing anything. After the user agrees,
///   ``confirmMeteredDownload(item:episodeID:connectionID:)`` queues it, as the legacy confirm
///   dialog did. Once approved, the download keeps going on the metered path.
/// - ``records`` and ``progress`` follow ``DownloadManager/events()`` from ``start()`` on, on top
///   of the records stored when it ran. A completed, cancelled or removed record leaves both.
/// - When ``AppSettings/downloadUsingCellular`` gets stricter (to ``CellularPolicy/never``), the
///   transfers under way restart under the new flags (``DownloadManager/restartActiveTransfers()``):
///   a running task keeps the network access it was created with. A looser policy, or a change
///   between ``CellularPolicy/always`` and ``CellularPolicy/ask``, keeps them: both allow every
///   network, and a download already under way isn't asked about again.
/// - Failed downloads aren't retried here; the user retries them.
///
/// The engine's `networkAccess` closure is ``networkAccess``'s ``DownloadNetworkAccess/provider``,
/// or a ``DownloadNetworkAccess`` on the same store when the engine is built first.
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

    /// The network access flags for new download tasks, read from the same store as the settings.
    public nonisolated let networkAccess: DownloadNetworkAccess

    @ObservationIgnored private let manager: any DownloadManaging
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let policy: NetworkPolicy
    @ObservationIgnored private let storedRecords: @Sendable () async throws -> [DownloadRecordDTO]
    @ObservationIgnored private let pathTimeout: Duration
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// The policy the transfers under way were last restarted for, or started under.
    @ObservationIgnored private var appliedPolicy: CellularPolicy
    /// Records that events changed or removed while the stored records were read, so the read
    /// doesn't bring back an older copy or a removed record; `nil` outside that read.
    @ObservationIgnored private var changedWhileLoading: Set<UUID>?

    /// Test hooks: called after an event, or a download cellular policy change, was handled.
    @ObservationIgnored var eventHandled: (@MainActor (DownloadManagerEvent) -> Void)?
    @ObservationIgnored var policyHandled: (@MainActor (CellularPolicy) -> Void)?

    /// - Parameters:
    ///   - manager: the app's ``DownloadManager``.
    ///   - monitor: the network path to check requests against.
    ///   - settings: the download cellular policy; its store also backs ``networkAccess``.
    ///   - storedRecords: the records stored when ``start()`` runs, for example
    ///     `DownloadStore.allRecords()`.
    ///   - treatsExpensiveAsCellular: as for ``NetworkPolicy``.
    ///   - pathTimeout: how long a request waits for the first network path before it is allowed.
    public init(
        manager: any DownloadManaging,
        monitor: NetworkMonitor,
        settings: AppSettings,
        storedRecords: @escaping @Sendable () async throws -> [DownloadRecordDTO],
        treatsExpensiveAsCellular: Bool = NetworkPolicy.treatsExpensiveAsCellularByDefault,
        pathTimeout: Duration = .milliseconds(500)
    ) {
        self.manager = manager
        self.settings = settings
        policy = NetworkPolicy(
            monitor: monitor, settings: settings, treatsExpensiveAsCellular: treatsExpensiveAsCellular)
        self.storedRecords = storedRecords
        self.pathTimeout = pathTimeout
        networkAccess = DownloadNetworkAccess(
            defaults: settings.defaults, treatsExpensiveAsCellular: treatsExpensiveAsCellular)
        appliedPolicy = settings.downloadUsingCellular
    }

    isolated deinit {
        for task in tasks { task.cancel() }
    }

    // MARK: - Lifecycle

    /// Subscribes to the manager's events, reads the stored records, and starts watching the
    /// download cellular policy. Later calls do nothing.
    public func start() async {
        guard !didStart else { return }
        didStart = true
        appliedPolicy = settings.downloadUsingCellular
        let settings = settings
        tasks.append(
            Task { [weak self] in
                let changes = Observations { @MainActor in settings.downloadUsingCellular }
                for await policy in changes {
                    guard let self else { return }
                    await self.apply(policy)
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
        changedWhileLoading = []
        defer { changedWhileLoading = nil }
        do {
            let stored = try await storedRecords()
            let changed = changedWhileLoading ?? []
            for record in stored where !changed.contains(record.id) {
                upsert(record)
            }
        } catch {
            Log.downloads.error(
                "Couldn't read the stored downloads: \(Log.redact(String(describing: error)), privacy: .public)")
        }
        // Progress that arrived meanwhile for a record that isn't listed.
        let listed = Set(records.map(\.id))
        progress = progress.filter { listed.contains($0.key) }
    }

    // MARK: - Requests

    /// Queues the download of a book, or of one podcast episode, if the download cellular policy
    /// allows it on the current path (waiting up to the path timeout for the first path).
    ///
    /// - Parameter item: an expanded item (`ItemEndpoints.item(id:)`) of the server `connectionID`.
    public func request(item: LibraryItem, episodeID: String?, connectionID: UUID) async -> DownloadRequestOutcome {
        switch await policy.canDownload(waitingUpTo: pathTimeout) {
        case .allowed: await enqueue(item: item, episodeID: episodeID, connectionID: connectionID)
        case .askUser(let reason): .needsConfirmation(reason)
        case .denied(let reason): .denied(reason)
        }
    }

    /// Queues a download the user agreed to after ``DownloadRequestOutcome/needsConfirmation(_:)``.
    /// Denied instead if the policy became ``CellularPolicy/never`` while they decided.
    public func confirmMeteredDownload(
        item: LibraryItem, episodeID: String?, connectionID: UUID
    ) async -> DownloadRequestOutcome {
        if case .denied(let reason) = policy.canDownload() { return .denied(reason) }
        return await enqueue(item: item, episodeID: episodeID, connectionID: connectionID)
    }

    private func enqueue(item: LibraryItem, episodeID: String?, connectionID: UUID) async -> DownloadRequestOutcome {
        do {
            return .started(
                try await manager.enqueue(
                    item: item, episodeID: episodeID, connectionID: connectionID, replacingExisting: false))
        } catch {
            return .failed(error)
        }
    }

    // MARK: - Policy

    /// Restarts the transfers under way when `policy` is stricter than the one they run under.
    private func apply(_ policy: CellularPolicy) async {
        let previous = appliedPolicy
        appliedPolicy = policy
        // Only `never` narrows the network access flags; `always` and `ask` allow every network.
        if policy == .never, previous != .never {
            do {
                try await manager.restartActiveTransfers()
            } catch {
                Log.downloads.error(
                    "Couldn't restart downloads for a stricter cellular policy: \(Log.redact(String(describing: error)), privacy: .public)"
                )
            }
        }
        policyHandled?(policy)
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
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            let index = records.firstIndex { $0.createdAt > record.createdAt } ?? records.endIndex
            records.insert(record, at: index)
        }
    }
}
