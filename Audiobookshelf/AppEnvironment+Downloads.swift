import ABSAppModel
import ABSCore
import ABSData
import ABSDownloads
import Foundation

/// The download stack (#73), built once by ``AppEnvironment``.
///
/// ``access`` is what screens queue downloads with (`\.downloadAccess`).
///
/// ``engine`` is kept here because ``DownloadEngineRegistry`` holds it weakly, for the
/// `.backgroundTask(.urlSession(...))` handler. ``lifecycle`` is registered as a session
/// participant, and the app passes it every scene phase.
@MainActor
struct AppDownloads {
    let engine: DownloadEngine
    let manager: DownloadManager
    let janitor: DownloadJanitor
    let controller: DownloadsController
    let lifecycle: DownloadsLifecycle
    let access: DownloadAccess

    /// - Parameters:
    ///   - root: the directory that holds `Downloads/` and `ResumeData/` (``DownloadLocations``);
    ///     the app's Application Support, never the App Group (ADR 0003). Tests pass a temporary
    ///     directory.
    ///   - makeSession: ``DownloadEngine/backgroundSession()`` in the app; tests pass a
    ///     non-background session.
    static func make(
        dataStack: DataStack, accounts: AccountManager, settings: AppSettings, root: URL,
        makeSession: @escaping DownloadSessionFactory
    ) -> AppDownloads {
        let locations = DownloadLocations(root: root)
        let store = DownloadStore(modelContainer: dataStack.container)
        let localItems = LocalItemStore(modelContainer: dataStack.container)
        // One instance for the engine and the controller, so the controller knows when metered
        // access was handed out.
        let networkAccess = DownloadNetworkAccess(defaults: settings.defaults)
        let engine = DownloadEngine(
            store: store, localItems: localItems,
            credentials: AccountDownloadCredentials { try await accounts.downloadAccess(for: $0, read: $1) },
            vault: ResumeDataVault(directory: locations.resumeDataRoot), locations: locations,
            networkAccess: networkAccess.provider, makeSession: makeSession)
        let manager = DownloadManager(
            store: store, localItems: localItems, engine: engine, locations: locations,
            capacity: VolumeStorageCapacity(locations: locations))
        // Takes the stack, so only the App Group store is swept (ADR 0003).
        let janitor = DownloadJanitor(
            manager: manager, connections: ServerConnectionStore(modelContainer: dataStack.container),
            dataStack: dataStack)
        let monitor = NetworkMonitor()
        let controller = DownloadsController(
            manager: manager, monitor: monitor, settings: settings, networkAccess: networkAccess,
            storedRecords: { try await store.allRecords() })
        let lifecycle = DownloadsLifecycle(
            engine: engine, manager: manager,
            records: { try await store.records(serverConnectionID: $0) },
            startController: {
                monitor.start()
                await controller.start()
            },
            sweep: {
                if case .aborted(let step) = await janitor.sweep().outcome {
                    Log.downloads.error(
                        "The download clean-up stopped at \(String(describing: step), privacy: .public)")
                }
            })
        return AppDownloads(
            engine: engine, manager: manager, janitor: janitor, controller: controller, lifecycle: lifecycle,
            access: DownloadAccess(
                requester: controller, status: StoredDownloadStatus(localItems: localItems, records: store)))
    }
}
