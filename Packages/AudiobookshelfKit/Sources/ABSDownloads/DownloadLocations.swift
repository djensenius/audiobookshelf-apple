import ABSCore
import Foundation

/// Where downloads and sealed resume data live: the app's private container, never the App
/// Group (ADR 0003). Stored paths are relative to ``downloadsRoot``, so they survive the
/// container moving (ADR 0002).
public struct DownloadLocations: Sendable {
    /// `Application Support/Downloads/`; part destinations are relative to it.
    public let downloadsRoot: URL
    /// `Application Support/ResumeData/`, for ``ResumeDataVault``.
    public let resumeDataRoot: URL

    /// - Parameter root: the directory that holds `Downloads/` and `ResumeData/`; tests pass a
    ///   temporary directory.
    public init(root: URL = .applicationSupportDirectory) {
        downloadsRoot = root.appending(path: "Downloads", directoryHint: .isDirectory)
        resumeDataRoot = root.appending(path: "ResumeData", directoryHint: .isDirectory)
    }

    public enum PathError: Error, Equatable {
        /// The stored path is empty, absolute, or leaves the downloads root.
        case invalidRelativePath(String)
    }

    /// The file URL for a path relative to ``downloadsRoot``.
    ///
    /// - Throws: ``PathError/invalidRelativePath(_:)`` for an empty or absolute path or one
    ///   with `.` or `..` components, so a stored path can't point outside the root.
    public func fileURL(forRelativePath path: String) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"),
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw PathError.invalidRelativePath(path) }
        return downloadsRoot.appending(path: path, directoryHint: .notDirectory)
    }

    /// Moves a finished download to `destination`, replacing any file there. Synchronous: the
    /// system deletes `location` once the delegate callback returns.
    ///
    /// The file gets `completeUntilFirstUserAuthentication` protection so it plays while the
    /// device is locked; failing to set it (for example on a volume without data protection)
    /// is logged, not fatal.
    static func moveFile(at location: URL, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try manager.replaceItemAt(destination, withItemAt: location)
        } else {
            try manager.moveItem(at: location, to: destination)
        }
        do {
            try manager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path(percentEncoded: false))
        } catch {
            Log.downloads.error(
                "Couldn't set file protection on a download: \(Log.redact(String(describing: error)), privacy: .public)"
            )
        }
    }

    /// The size of the file at `url`, or `nil` if it can't be read.
    static func fileSize(at url: URL) -> Int64? {
        (try? URL(filePath: url.path(percentEncoded: false)).resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init)
    }
}
