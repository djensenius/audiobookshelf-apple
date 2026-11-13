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
    /// Asked for server progress, which only the server has. The progress this device last saw
    /// from the server is a cache: handed to the coordinator as a fetch, it could confirm a pending
    /// PATCH and replay an older socket value over acknowledged progress.
    case serverProgressUnavailable
}

/// ``PlaybackSessionService`` for downloaded media on one connection (ADR 0007, decision 7). It
/// plays the files on this device and never contacts the server; the sessions it closes are kept
/// as ``PendingLocalSessionDTO``s for ``LocalSessionUploader``.
///
/// - ``startSession(itemID:episodeID:forceTranscode:)`` builds the session with
///   ``LocalPlaybackSessionBuilder``: play method local, a new UUIDv4 id, `deviceInfo`, and the
///   saved local position (legacy parity). It throws ``LocalPlaybackError/notDownloaded`` without
///   a download of the media, and ``LocalPlaybackError/downloadFilesMissing(_:)`` when one of its
///   files is missing. Only a server transcodes, so `forceTranscode` is ignored here; the
///   coordinator never forces one for downloaded files.
/// - ``resolveStream(for:)`` returns the files' URLs, with no transport or token.
/// - ``mediaProgress(itemID:episodeID:)`` throws ``LocalPlaybackError/serverProgressUnavailable``:
///   the coordinator takes its answer as the server's, so on failure it reads local progress itself.
/// - ``closeSession(id:report:)`` saves the session for upload, adding the report's listening time
///   to what is already saved under its id. Without a report (a superseded or failed start), a
///   session never saved is dropped.
/// - ``sessionStatus(id:)`` reports a session it started as open: no server can end it.
///
/// Saved sessions are shared by every connection in one store; this service only accepts its own
/// connection's.
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

    /// Whether `id` is a session this service started: still open, or saved for upload on its
    /// connection.
    public func owns(sessionID id: String) async -> Bool {
        if open.withLock({ $0[id] != nil }) { return true }
        return (try? await savedSession(id: id)) != nil
    }

    /// The saved session `id` if it belongs to this connection; another connection's with the same
    /// id is not this service's to read or replace.
    private func savedSession(id: String) async throws -> PendingLocalSessionDTO? {
        guard let session = try await progress.session(id: id), session.key.serverConnectionID == serverConnectionID
        else { return nil }
        return session
    }

    public func startSession(itemID: String, episodeID: String?, forceTranscode _: Bool) async throws
        -> PlaybackSession
    {
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

    /// Always throws ``LocalPlaybackError/serverProgressUnavailable``: this device can't answer for
    /// the server (see the type's documentation).
    public func mediaProgress(itemID: String, episodeID: String?) async throws -> MediaProgress? {
        throw LocalPlaybackError.serverProgressUnavailable
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
    /// added to the saved total. Without a report (the start was superseded, or its stream or load
    /// failed), a session never saved is dropped rather than uploaded unplayed, and a saved one is
    /// only marked inactive. A session this service doesn't know is ignored.
    public func closeSession(id: String, report: PlaybackSyncReport?) async throws {
        let started = open.withLock { $0[id] }
        let stored = try await progress.session(id: id)
        // Another connection's saved session with this id is never replaced.
        if let stored, stored.key.serverConnectionID != serverConnectionID {
            open.withLock { _ = $0.removeValue(forKey: id) }
            return
        }
        if report == nil, stored == nil {
            open.withLock { _ = $0.removeValue(forKey: id) }
            return
        }
        guard var session = stored ?? started else { return }
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
}
