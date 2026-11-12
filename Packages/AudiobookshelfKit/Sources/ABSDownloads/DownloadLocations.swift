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
    /// `Application Support/Transfers/`: one empty marker per part, written when its current
    /// transfer starts (see ``markTransferStart(partID:)``).
    let transfersRoot: URL
    /// `Application Support/SurvivorsToStop/`: one empty marker per quiesced connection whose
    /// surviving transfers no session listing has cancelled yet (see
    /// ``markSurvivorsToStop(connectionID:)``).
    let survivorsToStopRoot: URL

    /// - Parameter root: the directory that holds `Downloads/` and `ResumeData/`; tests pass a
    ///   temporary directory.
    public init(root: URL = .applicationSupportDirectory) {
        downloadsRoot = root.appending(path: "Downloads", directoryHint: .isDirectory)
        resumeDataRoot = root.appending(path: "ResumeData", directoryHint: .isDirectory)
        transfersRoot = root.appending(path: "Transfers", directoryHint: .isDirectory)
        survivorsToStopRoot = root.appending(path: "SurvivorsToStop", directoryHint: .isDirectory)
    }

    /// Creates ``downloadsRoot`` and ``resumeDataRoot`` if needed and excludes both from
    /// backups: downloads can be fetched again, and resume data is sealed to this device's key.
    /// Safe to call again; existing contents are kept.
    ///
    /// Both directories also get `completeUntilFirstUserAuthentication` protection, which new
    /// files inherit, so downloads play while the device is locked. Failing to set it (for
    /// example on a volume without data protection, as on many Macs) is logged, not fatal.
    ///
    /// - Throws: if a directory can't be created or excluded from backups.
    public func prepare() throws {
        let manager = FileManager.default
        for directory in [downloadsRoot, resumeDataRoot] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var directory = directory
            try directory.setResourceValues(values)
            do {
                try manager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: directory.path(percentEncoded: false))
            } catch {
                Log.downloads.error(
                    "Couldn't set file protection on a download directory: \(Log.redact(String(describing: error)), privacy: .public)"
                )
            }
        }
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
        // Split on scalars, not Characters: a `/` followed by a combining mark is one Character,
        // which would hide the boundary (`../\u{301}x` would pass as one component), but the file
        // system still sees the `/`. A component such as `..\u{301}` is an ordinary name.
        let components = path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.unicodeScalars.isEmpty, path.unicodeScalars.first != "/",
            components.allSatisfy({
                !$0.isEmpty && !$0.elementsEqual(".".unicodeScalars) && !$0.elementsEqual("..".unicodeScalars)
            })
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

    // MARK: - Transfer generations

    /// Records that a new transfer of `partID` starts now. A file at the part's destination
    /// modified after this marker was moved there by that transfer; an older one wasn't.
    func markTransferStart(partID: UUID) throws {
        try FileManager.default.createDirectory(at: transfersRoot, withIntermediateDirectories: true)
        try Data().write(
            to: transferMarker(partID: partID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Ends `partID`'s transfer generation, so no file at its destination counts as moved by it.
    func clearTransferMarker(partID: UUID) {
        try? FileManager.default.removeItem(at: transferMarker(partID: partID))
    }

    /// When `partID`'s current transfer started, or `nil` without a marker.
    func transferStart(partID: UUID) -> Date? {
        // A fresh URL, so no cached values are read.
        try? URL(filePath: transferMarker(partID: partID).path(percentEncoded: false))
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func transferMarker(partID: UUID) -> URL {
        transfersRoot.appending(path: partID.uuidString, directoryHint: .notDirectory)
    }

    // MARK: - Survivors to stop

    /// Records that `connectionID` was quiesced, so a later launch cancels its transfers that
    /// survived a relaunch instead of adopting them (ADR 0003). A file, not a store row: the
    /// marker matters most when the download store can't be read.
    func markSurvivorsToStop(connectionID: UUID) throws {
        try FileManager.default.createDirectory(at: survivorsToStopRoot, withIntermediateDirectories: true)
        try Data().write(
            to: survivorsToStopMarker(connectionID: connectionID),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Forgets `connectionID`'s marker once a session listing has cancelled its survivors.
    func clearSurvivorsToStop(connectionID: UUID) {
        try? FileManager.default.removeItem(at: survivorsToStopMarker(connectionID: connectionID))
    }

    /// The connections with a marker; empty when there are none or the directory can't be read.
    func connectionsWithSurvivorsToStop() -> Set<UUID> {
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: survivorsToStopRoot.path(percentEncoded: false)))
            ?? []
        return Set(names.compactMap(UUID.init(uuidString:)))
    }

    private func survivorsToStopMarker(connectionID: UUID) -> URL {
        survivorsToStopRoot.appending(path: connectionID.uuidString, directoryHint: .notDirectory)
    }

    /// Whether `error`, or an error it wraps, is `NSFileWriteOutOfSpaceError` or `ENOSPC`.
    static func isOutOfSpace(_ error: any Error) -> Bool {
        var next: NSError? = error as NSError
        for _ in 0..<8 {
            guard let error = next else { return false }
            if (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError)
                || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC))
            {
                return true
            }
            next = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
