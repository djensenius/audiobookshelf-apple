import ABSCore
import Foundation
import Observation

/// What the engine plays: a timeline and one URL per track.
public struct AudioEngineSource: Sendable, Hashable {
    public let timeline: PlaybackTimeline
    /// One URL per entry of ``PlaybackTimeline/tracks``, in the same order (not `session.audioTracks`
    /// order; use ``PlaybackTimeline/Track/sourceIndex`` to map).
    public let trackURLs: [URL]
    /// Loads assets with `AVURLAssetPreferPreciseDurationAndTimingKey`. Pass the mp3 seeking setting
    /// (`AppSettings.enableMp3IndexSeeking`): exact seeking in VBR mp3 files at the cost of a slower
    /// first load.
    public let prefersPreciseTiming: Bool
    /// Seek tolerance in seconds: `0` for direct play, up to `0.5` for HLS (ADR 0007).
    public let seekTolerance: Double
    /// Optional MIME type per entry of ``trackURLs`` (same order), passed as
    /// `AVURLAssetOverrideMIMETypeKey` for extensionless direct-play URLs (ADR 0007 §2). Empty, or a
    /// `nil` entry, means no override.
    public let trackMIMETypes: [String?]
    /// Network access flags for streamed tracks (``NetworkAccess/urlAssetOptions``), from the
    /// user's streaming cellular setting, so the transport enforces it after a path change.
    /// `nil` leaves AVFoundation's defaults; local files ignore them.
    public let networkAccess: NetworkAccess?
    /// Loads every track through this custom-header transport instead of a plain `AVURLAsset`
    /// (ADR 0007 §6). The source keeps it alive while its assets play.
    public let headerTransport: HeaderStreamingTransport?

    public init(
        timeline: PlaybackTimeline, trackURLs: [URL], trackMIMETypes: [String?] = [],
        networkAccess: NetworkAccess? = nil, headerTransport: HeaderStreamingTransport? = nil,
        prefersPreciseTiming: Bool = false, seekTolerance: Double = 0
    ) {
        self.timeline = timeline
        self.trackURLs = trackURLs
        self.trackMIMETypes = trackMIMETypes
        self.networkAccess = networkAccess
        self.headerTransport = headerTransport
        self.prefersPreciseTiming = prefersPreciseTiming
        self.seekTolerance = seekTolerance.isFinite ? max(seekTolerance, 0) : 0
    }

    func mimeType(trackIndex: Int) -> String? {
        trackMIMETypes.indices.contains(trackIndex) ? trackMIMETypes[trackIndex] : nil
    }
}

public enum PlaybackState: Sendable, Hashable {
    /// Nothing loaded.
    case idle
    /// Loading the media and seeking to the start position.
    case loading
    case paused
    /// Playback was requested but is waiting for data or for a seek to finish.
    case buffering
    case playing
    /// The last track played to its end.
    case ended
    /// An item failed. A seek retries (rebuilding the queue); the retry policy belongs to P2-06a.
    case failed(AudioEngineError)
}

public enum AudioEngineError: Error, Sendable, Hashable {
    /// The timeline has no playable tracks.
    case emptyTimeline
    /// ``AudioEngineSource/trackURLs`` does not have one URL per timeline track.
    case trackURLMismatch(expected: Int, actual: Int)
    /// The item for `tracks[trackIndex]` failed to load or play.
    case itemFailed(trackIndex: Int, PlaybackFailure)
    /// Another `load` or `stop` replaced this load before it finished.
    case superseded
    /// The player itself failed (`AVPlayer.status == .failed`). A seek or load replaces it.
    case playerFailed(PlaybackFailure)
    /// The audio session could not be activated, so playback did not start. Not a sticky failure.
    case audioSessionActivationFailed(description: String)
}

/// How a seek ended. Every seek gets an increasing generation; only the latest one can complete.
public enum SeekResult: Sendable, Hashable {
    /// The seek finished and ``AudioEngineProtocol/currentTime`` is its target.
    case completed
    /// A later seek, `load` or `stop` replaced it. It did not change the position.
    case superseded
    /// The player cancelled it (for example, the item was replaced) and no later seek exists.
    /// ``AudioEngineProtocol/pendingSeekTarget`` keeps the target so recovery can retry it.
    case interrupted
    /// Nothing is loaded, or the target item failed.
    case failed
}

public enum AudioEngineEvent: Sendable, Hashable {
    /// The periodic time observer fired while an item was ready; the payload is the global time.
    case tick(Double)
    /// The current track changed (an index into ``PlaybackTimeline/tracks``).
    case trackChanged(Int)
    /// The last track played to its end.
    case endOfMedia
    case failed(AudioEngineError)
    /// The audio output went away (``AudioEngineProtocol/pauseForOutputLoss()``), even if nothing
    /// was playing, so a play intent held outside the engine (recovery, a resume awaiting its
    /// seek) is dropped rather than restarting audio on the speaker.
    case outputLost
}

/// Activates the platform audio session around playback. Implemented by `AudioSessionController` on
/// iOS; macOS has no audio session.
@MainActor
public protocol AudioSessionActivating: AnyObject {
    /// Called before playback starts or resumes.
    func activate() throws
    /// Called when playback stops.
    func deactivate()
}

/// The playback engine, as seen by the layers above it. ``AudioEngine`` is the real implementation;
/// tests use fakes.
@MainActor
public protocol AudioEngineProtocol: AnyObject, Observable {
    var state: PlaybackState { get }
    /// Global time in seconds, last confirmed by the time observer or a completed seek.
    var currentTime: Double { get }
    var duration: Double { get }
    /// Index into ``PlaybackTimeline/tracks`` of the playing item.
    var currentTrackIndex: Int? { get }
    /// The rate playback starts at; kept across pauses, interruptions and item changes.
    var defaultRate: Float { get }
    /// Whether the user asked to play; stays `true` while buffering or seeking.
    var isPlaybackRequested: Bool { get }
    /// ``isPlaybackRequested`` when the latest ``AudioEngineEvent/failed(_:)`` happened: the
    /// failure clears it, and recovery resumes only playback that was wanted.
    var wasPlaybackRequestedAtFailure: Bool { get }
    /// Target of the latest seek until a seek to it completes.
    var pendingSeekTarget: Double? { get }
    /// Whether the engine has activated its audio session to play: set once activation succeeds,
    /// just before the player starts (after any load or seek in flight), and cleared by ``stop()``,
    /// ``unload()`` or a failed activation. A pause keeps it. With no audio session (macOS) it
    /// follows the same points.
    var isAudioSessionActive: Bool { get }
    var timeline: PlaybackTimeline? { get }
    var onEvent: (@MainActor (AudioEngineEvent) -> Void)? { get set }

    /// Replaces the queue and seeks to `time` (global seconds). Playback stays paused.
    func load(_ source: AudioEngineSource, at time: Double) async throws(AudioEngineError)
    func play()
    func pause()
    /// Pauses because the output went away, then reports ``AudioEngineEvent/outputLost``.
    func pauseForOutputLoss()
    /// Clears the queue and deactivates the audio session.
    func stop()
    /// Clears the queue as ``stop()`` does but leaves the audio session active, for switching
    /// items: deactivating notifies other apps, whose audio could resume briefly in between.
    /// ``isAudioSessionActive`` is cleared, as it describes the loaded media, and the next play
    /// activates again; if that activation fails, the kept session is deactivated (the media
    /// stays loaded for a retry). Call ``stop()`` when no item follows.
    func unload()
    /// Seeks to a global time, rebuilding the queue when the target is in another track.
    @discardableResult
    func seek(to time: Double) async -> SeekResult
    /// Sets ``defaultRate``; applies it immediately when playing. Ignores non-positive or non-finite rates.
    func setRate(_ rate: Float)
    /// Output volume, `0...1` (the sleep timer fade).
    var volume: Float { get }
    /// Sets ``volume``, clamped to `0...1`. Ignores non-finite values.
    func setVolume(_ volume: Float)
}
