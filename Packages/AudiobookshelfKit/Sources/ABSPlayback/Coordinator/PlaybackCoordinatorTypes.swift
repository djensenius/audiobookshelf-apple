import ABSAPI
import ABSCore
import ABSData
import Foundation

/// A saved position for an item: server progress, local progress or the last-played record.
public struct ProgressCandidate: Sendable, Hashable {
    public var currentTime: Double
    /// When the position was saved; `nil` counts as older than any dated candidate.
    public var updatedAt: Date?
    public var isFinished: Bool

    public init(currentTime: Double, updatedAt: Date?, isFinished: Bool = false) {
        self.currentTime = currentTime
        self.updatedAt = updatedAt
        self.isFinished = isFinished
    }
}

/// Where a fresh session starts (ADR 0007 point 7: newer progress wins).
public enum ResumePosition {
    /// - An explicit start time (a chapter, a bookmark) is used as is, with no rewind.
    /// - Otherwise the newest candidate wins (the first one on a tie), rewound by ``AutoRewind`` for
    ///   the time since it was saved. A finished item starts from `0`.
    /// - The result is clamped to `0...duration` when the duration is known.
    public static func startTime(
        explicit: Double?, candidates: [ProgressCandidate], duration: Double, now: Date, autoRewind: Bool
    ) -> Double {
        let time: Double
        if let explicit {
            time = explicit
        } else if let newest = candidates.filter({ $0.currentTime.isFinite }).max(by: isOlder) {
            time =
                newest.isFinished
                ? 0
                : AutoRewind.resumeTime(
                    currentTime: newest.currentTime, lastPlayed: newest.updatedAt, now: now, isEnabled: autoRewind)
        } else {
            time = 0
        }
        let finite = time.isFinite ? max(time, 0) : 0
        return duration > 0 ? min(finite, duration) : finite
    }

    private static func isOlder(_ lhs: ProgressCandidate, _ rhs: ProgressCandidate) -> Bool {
        switch (lhs.updatedAt, rhs.updatedAt) {
        case (nil, .some): true
        case (.some(let left), .some(let right)): left < right
        default: false
        }
    }
}

/// Why playback couldn't start or stopped.
public enum PlaybackCoordinatorError: Error, Sendable, Equatable {
    /// The path is metered and the streaming setting is "ask": ask the user, then play `key` with
    /// `play(…, allowingMeteredNetwork: true)`. No session was started.
    case streamingNeedsConfirmation(MeteredReason, key: MediaKey)
    /// The path is metered and the streaming setting is "never". No session was started for `key`.
    case streamingNotAllowed(MeteredReason, key: MediaKey)
    case sessionStartFailed(APIError)
    case streamUnavailable(StreamResolutionError)
    /// The engine couldn't load the media.
    case engine(AudioEngineError)
    /// An item or the player failed while loading or playing.
    case playback(PlaybackFailure)
    /// Any other error, by description.
    case unexpected(String)

    init(engineError: AudioEngineError) {
        switch engineError {
        case .itemFailed(_, let failure), .playerFailed(let failure): self = .playback(failure)
        default: self = .engine(engineError)
        }
    }
}

/// Why a server session is being closed.
public enum SessionCloseReason: Sendable, Hashable {
    /// Another item was played.
    case itemChanged
    /// The same item was played again from the start of a new session.
    case restarted
    /// ``PlaybackCoordinator/stop()``.
    case stopped
    /// The engine couldn't load the session's media.
    case loadFailed
}

/// A session being closed, as handed to observers and ``PlaybackCoordinator/finalCloseReport``.
public struct ClosingSession: Sendable, Hashable {
    public let sessionID: String
    public let key: MediaKey
    /// The global position: when loaded, the engine's confirmed time or the target of a seek that
    /// hadn't landed (an interrupted seek leaves the engine's own time behind, at 0 after a load);
    /// else the position the load was going to start from.
    public let currentTime: Double
    public let duration: Double
    /// Whether the engine loaded the media. A session that never loaded never played, so the
    /// coordinator closes it without asking ``PlaybackCoordinator/finalCloseReport``.
    public let wasLoaded: Bool
    public let reason: SessionCloseReason
}

/// What happened, for code that follows playback without owning it: progress sync and history
/// (P2-06b), Now Playing (P2-07) and the sleep timer (P2-08).
public enum PlaybackCoordinatorEvent: Sendable, Equatable {
    /// The current media changed; `nil` after ``PlaybackCoordinator/stop()``.
    case itemChanged(MediaKey?)
    /// A server session became the current one.
    case sessionStarted(sessionID: String, key: MediaKey)
    /// The engine loaded the media at `time`, after the resume seek (including auto-rewind). When
    /// that seek was interrupted, `time` is its target and ``didSeek(time:)`` follows once it lands.
    case loaded(time: Double)
    /// The engine accepted the request to play (it may still be buffering, or waiting for a seek
    /// to land). Not sent when it refuses, such as when the audio session won't activate:
    /// ``failed(_:)`` is sent instead.
    case playbackStarted
    case paused(time: Double)
    /// A seek completed and playback is at `time`. For a load whose initial seek was interrupted,
    /// sent once when it lands, never for the position 0 the engine reports meanwhile.
    case didSeek(time: Double)
    /// The engine's periodic time update while media is loaded.
    case tick(time: Double)
    case ended
    case failed(PlaybackCoordinatorError)
    /// Every ``sessionStarted(sessionID:key:)`` gets one, after the synchronous final handoff.
    /// An allowed close request starts only once the main actor is free, so observers see this
    /// first. No-network account end deliberately skips transport, not the loaded position receipt.
    case sessionWillClose(ClosingSession)
}

/// Identifies an observer added with ``PlaybackCoordinator/addObserver(_:)``.
public struct PlaybackObserverToken: Sendable, Hashable {
    let id = UUID()
}
