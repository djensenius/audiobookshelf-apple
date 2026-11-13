import ABSAppModel
import ABSData
import ABSDownloads
import Foundation

extension AppEnvironment {
    /// What the Downloads tab is built from (`\.downloads`), or `nil` without a download stack.
    ///
    /// Each read of the items uses a fresh `LocalItemStore`, so its context holds nothing stale.
    /// The stack's instance, the items' only writer, streams its updates, so every Downloads
    /// window reads them again after any write: a completed download, or a deletion in another
    /// window. The free space is that of the volume holding the downloads root
    /// ``AppEnvironment/shared`` uses, and downloaded files (such as covers) are found under it.
    func makeDownloadsServices() -> DownloadsServices? {
        guard let downloads, let dataStack else { return nil }
        let container = dataStack.container
        let writer = downloads.localItems
        let locations = DownloadLocations(root: .applicationSupportDirectory)
        let capacity = VolumeStorageCapacity(locations: locations)
        return DownloadsServices(
            controller: downloads.controller, control: downloads.manager,
            localItemUpdates: { try await writer.updates(serverConnectionID: $0) },
            localItems: { try await LocalItemStore(modelContainer: container).items(serverConnectionID: $0) },
            localItem: { try await LocalItemStore(modelContainer: container).item(id: $0) },
            localFileURL: { try? locations.fileURL(forRelativePath: $0) },
            availableCapacity: { try capacity.availableCapacity() })
    }
}
