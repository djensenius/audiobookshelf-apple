import ABSAPI
import ABSCore
import ABSData
import Foundation
import Synchronization

/// Reads downloaded items; ``LocalItemStore`` conforms.
public protocol LocalItemReading: Sendable {
    func item(serverConnectionID: UUID, libraryItemId: String) async throws -> LocalLibraryItemDTO?
}

extension LocalItemStore: LocalItemReading {}

/// Why ``LocalPlaybackSessionService`` can't start a session.
public enum LocalPlaybackError: Error, Sendable, Hashable {
    /// The media has no completed download on this device: it streams.
    case notDownloaded
    /// The media has a completed download, but a file it plays is missing or unreadable. ADR 0007
    /// §7: a download never falls back to streaming silently, so this is shown with a "Stream
    /// instead" action (``PreferringLocalSessionService/streamInstead(_:)``).
    case downloadFilesMissing(MediaKey)
}

/// ``PlaybackSessionService`` for downloaded media on one connection (ADR 0007, decision 7). It
/// plays the files on this device and never contacts the server; the sessions it closes are kept
/// as ``PendingLocalSessionDTO``s for ``LocalSessionUploader``.
///
/// - ``startSession(itemID:episodeID:)`` builds the session with ``LocalPlaybackSessionBuilder``:
///   play method local, a new UUIDv4 id, `deviceInfo`, and the saved local position (legacy
///   parity). It throws ``LocalPlaybackError/notDownloaded`` without a download of the media, and
///   ``LocalPlaybackError/downloadFilesMissing(_:)`` when one of its files is missing.
/// - ``resolveStream(for:)`` returns the files' URLs, with no transport or token.
/// - ``mediaProgress(itemID:episodeID:)`` is the server progress this device last saw for the
///   media (the local row's server baseline), never the local position: the coordinator takes this
///   as the server's answer, and a local edit taken as one would be marked as synced.
/// - ``closeSession(id:report:)`` saves the session for upload, adding the report's listening time
///   to what is already saved under its id.
/// - ``sessionStatus(id:)`` reports a session it started as open: no server can end it.
public final class LocalPlaybackSessionService: PlaybackSessionService {
    public let serverConnectionID: UUID
    private let items: any LocalItemReading
    private let progress: LocalProgressStore
    private let fileURL: @Sendable (String) throws -> URL
    private let fileExists: @Sendable (URL) -> Bool
    private let deviceIdentifiers: (any DeviceIdentifying)?
    private let now: @Sendable () -> Date
    /// The sessions started and not yet closed, as they would be saved.
    private let open = Mutex<[String: PendingLocalSessionDTO]>([:])

    /// - Parameters:
    ///   - fileURL: The file URL for a path relative to the downloads root, throwing for a path that
    ///     leaves it (`DownloadLocations.fileURL(forRelativePath:)` in the app).
    ///   - fileExists: Whether a file is on disk; tests replace it.
    ///   - deviceIdentifiers: For the session's `deviceInfo`; `nil` leaves it out.
    public init(
        serverConnectionID: UUID, items: any LocalItemReading, progress: LocalProgressStore,
        fileURL: @escaping @Sendable (String) throws -> URL,
        fileExists: @escaping @Sendable (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        },
        deviceIdentifiers: (any DeviceIdentifying)? = nil, now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.serverConnectionID = serverConnectionID
        self.items = items
        self.progress = progress
        self.fileURL = fileURL
        self.fileExists = fileExists
        self.deviceIdentifiers = deviceIdentifiers
        self.now = now
    }

    /// The downloaded item when every file the book or episode `episodeID` plays exists; `nil` when
    /// the media has no download (``LocalPlaybackSessionBuilder/hasDownload(of:episodeID:)``).
    ///
    /// - Throws: ``LocalPlaybackError/downloadFilesMissing(_:)`` when it has one but a file it plays
    ///   is missing, has no file record, or its path is invalid.
    public func playableItem(itemID: String, episodeID: String?) async throws -> LocalLibraryItemDTO? {
        guard let item = try await items.item(serverConnectionID: serverConnectionID, libraryItemId: itemID),
            LocalPlaybackSessionBuilder.hasDownload(of: item, episodeID: episodeID)
        else { return nil }
        guard let paths = LocalPlaybackSessionBuilder.relativePaths(of: item, episodeID: episodeID),
            paths.allSatisfy({ (try? fileURL($0)).map(fileExists) == true })
        else {
            throw LocalPlaybackError.downloadFilesMissing(
                MediaKey(serverConnectionID: serverConnectionID, libraryItemId: itemID, episodeId: episodeID))
        }
        return item
    }

    /// Whether `id` is a session this service started: still open, or saved for upload.
    public func owns(sessionID id: String) async -> Bool {
        if open.withLock({ $0[id] != nil }) { return true }
        return (try? await progress.session(id: id)) != nil
    }

    public func startSession(itemID: String, episodeID: String?) async throws -> PlaybackSession {
        guard let item = try await playableItem(itemID: itemID, episodeID: episodeID) else {
            throw LocalPlaybackError.notDownloaded
        }
        let key = MediaKey(serverConnectionID: serverConnectionID, libraryItemId: itemID, episodeId: episodeID)
        let currentTime = try await progress.progress(for: key)?.currentTime ?? 0
        var deviceInfo: DeviceInfo?
        if let deviceIdentifiers {
            deviceInfo = PlaybackDeviceInfo.make(deviceID: await deviceIdentifiers.deviceIdentifier())
        }
        let startedAt = now()
        guard
            let session = LocalPlaybackSessionBuilder.session(
                for: item, episodeID: episodeID, id: UUID().uuidString, currentTime: currentTime,
                startedAt: startedAt, deviceInfo: deviceInfo)
        else { throw LocalPlaybackError.notDownloaded }
        let pending = PendingLocalSessionDTO(
            id: session.id, key: key, userId: item.serverUserId, mediaType: item.mediaType,
            displayTitle: session.displayTitle ?? item.title, displayAuthor: session.displayAuthor,
            duration: session.duration, startTime: currentTime, startedAt: startedAt, updatedAt: startedAt,
            currentTime: currentTime)
        open.withLock { $0[session.id] = pending }
        return session
    }

    /// The local row's server baseline, or `nil` without one.
    public func mediaProgress(itemID: String, episodeID: String?) async throws -> MediaProgress? {
        let key = MediaKey(serverConnectionID: serverConnectionID, libraryItemId: itemID, episodeId: episodeID)
        guard let baseline = try await progress.progress(for: key)?.serverBaseline else { return nil }
        return MediaProgress(
            id: key.rawValue, libraryItemId: itemID, episodeId: episodeID, duration: baseline.duration,
            progress: baseline.progress, currentTime: baseline.currentTime, isFinished: baseline.isFinished,
            ebookLocation: baseline.ebookLocation, ebookProgress: baseline.ebookProgress,
            lastUpdate: Self.milliseconds(baseline.lastUpdate), finishedAt: baseline.finishedAt.map(Self.milliseconds))
    }

    /// - Throws: ``StreamResolutionError/resolution(_:)`` with
    ///   ``TrackURLResolutionError/unsupportedPlayMethod(_:)`` for a session that isn't local,
    ///   ``TrackURLResolutionError/noTracks`` without tracks, and
    ///   ``TrackURLResolutionError/invalidContentURL`` when a track's file path is invalid or the
    ///   file is gone.
    public func resolveStream(for session: PlaybackSession) async throws -> ResolvedStream {
        guard session.playMethod == .local else {
            throw StreamResolutionError.resolution(.unsupportedPlayMethod(session.playMethod))
        }
        guard !session.audioTracks.isEmpty else { throw StreamResolutionError.resolution(.noTracks) }
        var files: [(url: URL, mimeType: String?, startOffset: Double, duration: Double)] = []
        for track in session.audioTracks {
            guard let path = track.contentUrl, let url = try? fileURL(path), fileExists(url) else {
                throw StreamResolutionError.resolution(.invalidContentURL)
            }
            files.append((url, track.mimeType, track.startOffset ?? 0, track.duration))
        }
        return ResolvedStream(plan: .localFiles(files), urls: files.map(\.url))
    }

    /// Saves session `id` for upload, inactive: `currentTime` from `report`, and its listening time
    /// added to the saved total. A session this service doesn't know is ignored.
    public func closeSession(id: String, report: PlaybackSyncReport?) async throws {
        let started = open.withLock { $0[id] }
        guard var session = try await progress.session(id: id) ?? started else { return }
        if let report {
            session.currentTime = report.currentTime
            session.timeListening += report.timeListened
            if report.duration > 0 { session.duration = report.duration }
        }
        session.updatedAt = now()
        session.isActive = false
        try await progress.saveSession(session)
        open.withLock { _ = $0.removeValue(forKey: id) }
    }

    /// Nothing to refresh: local files need no token.
    public func refreshStreamAccess(replacing rejected: String?) async throws {}

    /// ``PlaybackSessionStatus/alive`` for a session this service started, else
    /// ``PlaybackSessionStatus/unknown``.
    public func sessionStatus(id: String) async -> PlaybackSessionStatus {
        await owns(sessionID: id) ? .alive : .unknown
    }

    private static func milliseconds(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 * 1000).rounded())
    }
}
