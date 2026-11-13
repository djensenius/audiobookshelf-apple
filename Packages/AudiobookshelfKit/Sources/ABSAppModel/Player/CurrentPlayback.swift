import ABSCore
import ABSData
import ABSPlayback
import Observation

/// The signed-in account's playback, for the app's one ``PlayerViewModel`` (#183): forwards to the
/// current scope's coordinator, which the session participant re-binds on each account session.
/// Unbound (no account, or between accounts) it's idle and ignores commands.
///
/// Observers follow a re-bind. Observation reports a change on `willSet`, and a tracker that
/// observes again from its `onChange` (as ``PlayerViewModel`` does, to capture the outgoing
/// display) re-registers while the old binding is still in place, so it would keep watching the
/// old coordinator. So every getter also reads ``bindingEpoch``, which ``bind(_:)`` advances
/// after assigning the new binding: that second change makes such trackers observe again, now
/// against the new one.
@MainActor
@Observable
public final class CurrentPlayback: PlayerPlaybackControlling {
    /// The bound playback, or `nil`.
    public private(set) var current: (any PlayerPlaybackControlling)?
    /// Advanced after each re-bind, so trackers that re-registered on the old binding move on.
    private var bindingEpoch = 0

    public init() {}

    /// Makes `playback` the one forwarded to, or none. Observers see the change twice: first while
    /// the old binding is readable, then with the new one.
    public func bind(_ playback: (any PlayerPlaybackControlling)?) {
        current = playback
        bindingEpoch &+= 1
    }

    /// The current binding, read with its epoch so the caller's tracking follows a re-bind.
    private var bound: (any PlayerPlaybackControlling)? {
        _ = bindingEpoch
        return current
    }

    public var phase: PlaybackCoordinator.Phase { bound?.phase ?? .idle }
    public var mediaKey: MediaKey? { bound?.mediaKey }
    public var session: PlaybackSession? { bound?.session }
    public var restoredRecord: LastPlayedRecord? { bound?.restoredRecord }
    public var error: PlaybackCoordinatorError? { bound?.error }
    public var currentTime: Double { bound?.currentTime ?? 0 }
    public var duration: Double { bound?.duration ?? 0 }
    public var rate: Double { bound?.rate ?? 1 }
    public var isPlaying: Bool { bound?.isPlaying ?? false }
    public var isBuffering: Bool { bound?.isBuffering ?? false }
    public var isPlaybackRequested: Bool { bound?.isPlaybackRequested ?? false }
    public var timeline: PlaybackTimeline? { bound?.timeline }
    public var chapterIndex: Int? { bound?.chapterIndex }
    public var chapter: Chapter? { bound?.chapter }
    public var chapterRange: TimelineRange? { bound?.chapterRange }
    public var chapterElapsed: Double? { bound?.chapterElapsed }
    public var chapterRemaining: Double? { bound?.chapterRemaining }

    public func resume(rewindingBy seconds: Double?) async {
        await current?.resume(rewindingBy: seconds)
    }

    public func pause() {
        current?.pause()
    }

    @discardableResult public func seek(to time: Double) async -> Double? {
        await current?.seek(to: time)
    }

    @discardableResult public func jump(by offset: Double) async -> Double? {
        await current?.jump(by: offset)
    }

    @discardableResult public func jumpOutcome(by offset: Double) async -> JumpOutcome {
        await current?.jumpOutcome(by: offset) ?? .deferred
    }

    public func setRate(_ rate: Double) {
        current?.setRate(rate)
    }

    public func stop(reason: PlaybackStopReason) {
        current?.stop(reason: reason)
    }

    public func confirmMeteredStreaming() async {
        await current?.confirmMeteredStreaming()
    }

    public func declineMeteredStreaming() {
        current?.declineMeteredStreaming()
    }

    public func handleStreamReset(sessionID: String) {
        current?.handleStreamReset(sessionID: sessionID)
    }
}
