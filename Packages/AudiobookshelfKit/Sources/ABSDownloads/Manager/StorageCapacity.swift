import Foundation

/// Reports how many bytes downloads may still use.
public protocol StorageCapacityProviding: Sendable {
    /// The bytes available for new downloads.
    ///
    /// - Throws: when the capacity can't be read.
    func availableCapacity() async throws -> Int64
}

/// The capacity of the volume that holds ``DownloadLocations/downloadsRoot``, as
/// `volumeAvailableCapacityForImportantUsage`: what the system can free for a download the user
/// asked for, which counts purgeable space and so is more than the plain free space.
public struct VolumeStorageCapacity: StorageCapacityProviding {
    public enum CapacityError: Error, Equatable {
        /// The volume didn't report a capacity.
        case unavailable
    }

    private let locations: DownloadLocations

    public init(locations: DownloadLocations) {
        self.locations = locations
    }

    public func availableCapacity() throws -> Int64 {
        // The downloads folder may not exist yet; any existing ancestor is on the same volume.
        var url = locations.downloadsRoot
        while !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            let parent = url.deletingLastPathComponent()
            guard parent != url else { break }
            url = parent
        }
        // A fresh URL, so no cached values are read.
        let values = try URL(filePath: url.path(percentEncoded: false))
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage else { throw CapacityError.unavailable }
        return capacity
    }
}
