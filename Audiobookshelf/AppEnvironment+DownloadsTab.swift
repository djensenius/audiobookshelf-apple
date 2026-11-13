import ABSAppModel
import ABSData
import ABSDownloads
import Foundation

extension AppEnvironment {
    /// What the Downloads tab is built from (`\.downloads`), or `nil` without a download stack.
    ///
    /// Each read of the items uses a fresh `LocalItemStore`, so its context holds nothing stale:
    /// the stack's instance isn't kept, and these reads don't need its update streams, since
    /// ``DownloadsTabModel`` reads again after each completion and deletion. The free space is
    /// that of the volume holding the downloads root ``AppEnvironment/shared`` uses.
    func makeDownloadsServices() -> DownloadsServices? {
        guard let downloads, let dataStack else { return nil }
        let container = dataStack.container
        let capacity = VolumeStorageCapacity(locations: DownloadLocations(root: .applicationSupportDirectory))
        return DownloadsServices(
            controller: downloads.controller, control: downloads.manager,
            localItems: { try await LocalItemStore(modelContainer: container).items(serverConnectionID: $0) },
            availableCapacity: { try capacity.availableCapacity() })
    }
}
