import ABSCore
import Foundation

/// The media a playback history event belongs to.
public struct PlaybackHistoryMedia: Sendable, Hashable {
    public var key: MediaKey
    /// The title shown on the history page, e.g. the book or episode title.
    public var displayTitle: String

    public init(key: MediaKey, displayTitle: String) {
        self.key = key
        self.displayTitle = displayTitle
    }
}

/// The outcome of the progress sync an event reports (legacy `SyncResult`).
public enum PlaybackHistorySyncResult: Sendable, Hashable {
    /// Saved on the device only (offline, local item, or a sync that was skipped).
    case notAttempted
    case succeeded
    case failed(message: String?)
}

/// Records playback history events. The app gives the only instance to `ProgressSyncer`
/// (ABSPlayback), which records the events of the sessions it follows (#384).
///
/// Port of the legacy `MediaEventManager`. Record each event after it happened, with the
/// playback position (seconds from the start of the media) at that moment:
///
/// - ``PlaybackHistoryEventName/play``: playback starts or resumes, at the start position.
///   `sync` is `.notAttempted`.
/// - ``PlaybackHistoryEventName/pause``: the user (or a sleep timer, interruption or route
///   change) paused, after the progress sync that pausing triggers, with its result.
/// - ``PlaybackHistoryEventName/stop``: the session closed (another item started, the player was
///   dismissed, sign-out), after the final sync, with its result.
/// - ``PlaybackHistoryEventName/finished``: playback reached the end, at the duration, after the
///   sync that marks the item finished, with its result.
/// - ``PlaybackHistoryEventName/seek``: a seek finished (scrubbing, jumps, chapter skips), at the
///   new position. `sync` is `.notAttempted`.
/// - ``PlaybackHistoryEventName/save``: each periodic progress save while playing, with the result
///   of the server sync that went with it, or `.notAttempted` for a local-only save.
/// - ``PlaybackHistoryEventName/sync``: progress for the media arrived from the server (socket
///   event or fetch) and replaced the local position, at the server's position, with `details`
///   saying where it came from. Ignored unless the media already has history, as in legacy.
///
/// Recording never throws: history is best effort and must not interrupt playback, so failures
/// are logged and the event is dropped. Each media keeps its own history, pruned by the store:
/// at most `PlaybackHistoryStore.maxEventsPerMedia` events, the oldest saves and syncs evicted
/// first, and none older than `PlaybackHistoryStore.retention`.
public protocol PlaybackHistoryRecording: Sendable {
    func record(
        _ name: PlaybackHistoryEventName,
        for media: PlaybackHistoryMedia,
        at position: TimeInterval?,
        sync: PlaybackHistorySyncResult,
        details: String?
    ) async
}

extension PlaybackHistoryRecording {
    /// Records an event with no sync result and no details.
    public func record(_ name: PlaybackHistoryEventName, for media: PlaybackHistoryMedia, at position: TimeInterval?)
        async
    {
        await record(name, for: media, at: position, sync: .notAttempted, details: nil)
    }
}

/// Writes events to a ``PlaybackHistoryStore``, timestamped by `now`.
public struct PlaybackHistoryRecorder: PlaybackHistoryRecording {
    private let store: PlaybackHistoryStore
    private let now: @Sendable () -> Date

    public init(store: PlaybackHistoryStore, now: @escaping @Sendable () -> Date = { .now }) {
        self.store = store
        self.now = now
    }

    public func record(
        _ name: PlaybackHistoryEventName,
        for media: PlaybackHistoryMedia,
        at position: TimeInterval?,
        sync: PlaybackHistorySyncResult,
        details: String?
    ) async {
        do {
            let event = self.event(name, for: media, at: position, sync: sync, details: details)
            try await store.record(event, onlyIfHistoryExists: name == .sync)
        } catch {
            Log.data.error(
                "Couldn't record a \(name.rawValue, privacy: .public) history event: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func event(
        _ name: PlaybackHistoryEventName,
        for media: PlaybackHistoryMedia,
        at position: TimeInterval?,
        sync: PlaybackHistorySyncResult,
        details: String?
    ) -> PlaybackHistoryEventDTO {
        let (attempted, success, message): (Bool, Bool?, String?) =
            switch sync {
            case .notAttempted: (false, nil, nil)
            case .succeeded: (true, true, nil)
            case .failed(let message): (true, false, message)
            }
        return PlaybackHistoryEventDTO(
            serverConnectionID: media.key.serverConnectionID,
            mediaKey: media.key,
            mediaDisplayTitle: media.displayTitle,
            name: name,
            type: name == .sync ? .sync : .playback,
            details: details,
            currentTime: position.flatMap { $0.isFinite ? max($0, 0) : nil },
            serverSyncAttempted: attempted,
            serverSyncSuccess: success,
            serverSyncMessage: message,
            timestamp: now()
        )
    }
}
