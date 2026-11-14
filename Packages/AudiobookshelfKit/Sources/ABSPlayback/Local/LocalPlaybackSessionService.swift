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

/// Where a ``PlaybackScope`` finds downloaded media, to play it from its files (#74): the
/// downloaded items, and the file URL of a path relative to the downloads root.
public struct LocalDownloadFiles: Sendable {
    public var items: any LocalItemReading
    /// Throws for a path that leaves the downloads root (`DownloadLocations.fileURL(forRelativePath:)`
    /// in the app).
    public var fileURL: @Sendable (String) throws -> URL
    /// Whether a file is on disk; tests replace it.
    public var fileExists: @Sendable (URL) -> Bool

    public init(
        items: any LocalItemReading, fileURL: @escaping @Sendable (String) throws -> URL,
        fileExists: @escaping @Sendable (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        }
    ) {
        self.items = items
        self.fileURL = fileURL
        self.fileExists = fileExists
    }
}

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
/// Each session's saves and its close are its own row's only writers, and each reads the row then
/// writes it back. They run one at a time per session id, in the order called, whatever awaits or
/// cancels their callers, and a session closed here stays closed: a later ``syncSession(id:report:)``
/// for it only adds its listening time to the closed row, which stays inactive with the close's
/// position, so it never reopens it or replaces its totals with older ones (#74). So however a
/// teardown's deadline cuts its wait for a save short, the save and the close can't overlap.
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
    /// The sessions started and not yet closed, each as last saved, or as started until it is
    /// (#74). The open snapshot is the session's cumulative state: its saved row is only a copy,
    /// which an upload may delete while it plays (the first sync after login deletes active
    /// sessions too), and the next save starts from the snapshot, never from zero.
    private let open = Mutex<[String: OpenSession]>([:])

    /// Per session id, the last save or close called: the next one waits for it (#74).
    private let tails = Mutex<[String: (token: UUID, task: Task<Void, Never>)]>([:])
    /// The sessions closed here: a save for one only adds its listening time, so none reopens (#74).
    private let closed = Mutex<Set<String>>([])
    /// Tests only: runs between a write's read of the saved row and its save, to hold it there.
    let afterRead = Mutex<(@Sendable (String) async -> Void)?>(nil)

    private struct OpenSession {
        var session: PendingLocalSessionDTO
        /// Whether it was saved: a close without a report then still saves it.
        var isSaved: Bool
    }

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

    /// Whether the book or episode `episodeID` has a completed download on this connection
    /// (``LocalPlaybackSessionBuilder/hasDownload(of:episodeID:)``), whether or not its files are
    /// all there; `false` when the store can't be read.
    public func hasDownload(itemID: String, episodeID: String?) async -> Bool {
        guard let item = try? await items.item(serverConnectionID: serverConnectionID, libraryItemId: itemID)
        else { return false }
        return LocalPlaybackSessionBuilder.hasDownload(of: item, episodeID: episodeID)
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
        open.withLock { $0[session.id] = OpenSession(session: pending, isSaved: false) }
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
    /// only marked inactive, even when an upload already deleted its row. A session this service
    /// doesn't know is ignored.
    public func closeSession(id: String, report: PlaybackSyncReport?) async throws {
        try await serialized(id) { [self] in
            closed.withLock { _ = $0.insert(id) }
            try await close(id: id, report: report)
        }
    }

    private func close(id: String, report: PlaybackSyncReport?) async throws {
        let started = open.withLock { $0[id] }
        let stored = try await progress.session(id: id)
        await afterRead.withLock { $0 }?(id)
        // Another connection's saved session with this id is never replaced.
        if let stored, stored.key.serverConnectionID != serverConnectionID {
            open.withLock { _ = $0.removeValue(forKey: id) }
            return
        }
        if report == nil, stored == nil, started?.isSaved != true {
            open.withLock { _ = $0.removeValue(forKey: id) }
            return
        }
        guard var session = stored ?? started?.session else { return }
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

    /// Saves session `id` for upload while it plays, still active: `currentTime` from `report`, and
    /// its listening time added to the saved total, as ``closeSession(id:report:)`` does (#74). The
    /// progress syncer's periodic report for a local session
    /// (``LocalSessionProgressSyncService``), so offline listening survives a relaunch. A session
    /// this service doesn't know, or another connection's saved one with its id, is ignored.
    /// After ``closeSession(id:report:)`` for `id` (a save the syncer had begun as playback
    /// stopped), only its listening time is added, to the saved row: it stays inactive, at the
    /// close's position.
    public func syncSession(id: String, report: PlaybackSyncReport) async throws {
        try await serialized(id) { [self] in
            try await sync(id: id, report: report, isClosed: closed.withLock { $0.contains(id) })
        }
    }

    private func sync(id: String, report: PlaybackSyncReport, isClosed: Bool) async throws {
        let started = open.withLock { $0[id] }
        let stored = try await progress.session(id: id)
        await afterRead.withLock { $0 }?(id)
        if let stored, stored.key.serverConnectionID != serverConnectionID { return }
        if isClosed {
            // The close's position and `updatedAt` stay; an upload in flight still sees the
            // change, since settlement compares every field it sent.
            guard var session = stored, report.timeListened > 0 else { return }
            session.timeListening += report.timeListened
            return try await progress.saveSession(session)
        }
        guard var session = stored ?? started?.session else { return }
        session.currentTime = report.currentTime
        session.timeListening += report.timeListened
        if report.duration > 0 { session.duration = report.duration }
        session.updatedAt = now()
        session.isActive = true
        try await progress.saveSession(session)
        // The snapshot is now this save, so an upload deleting the row loses nothing; a session
        // closed meanwhile isn't reopened.
        let saved = session
        open.withLock { if $0[id] != nil { $0[id] = OpenSession(session: saved, isSaved: true) } }
    }

    /// Runs `body` after every write to `id` called before it, in a task of its own, so a caller's
    /// cancellation neither skips it nor lets the next one start before it ends (#74).
    private func serialized(_ id: String, _ body: @escaping @Sendable () async throws -> Void) async throws {
        let token = UUID()
        let task = tails.withLock { tails in
            let previous = tails[id]?.task
            let task = Task<Void, any Error> {
                await previous?.value
                try await body()
            }
            tails[id] = (token, Task { _ = try? await task.value })
            return task
        }
        defer { tails.withLock { if $0[id]?.token == token { $0[id] = nil } } }
        try await task.value
    }

    /// Nothing to refresh: local files need no token.
    public func refreshStreamAccess(replacing rejected: String?) async throws {}

    /// ``PlaybackSessionStatus/alive`` for a session this service started, else
    /// ``PlaybackSessionStatus/unknown``.
    public func sessionStatus(id: String) async -> PlaybackSessionStatus {
        await owns(sessionID: id) ? .alive : .unknown
    }
}
