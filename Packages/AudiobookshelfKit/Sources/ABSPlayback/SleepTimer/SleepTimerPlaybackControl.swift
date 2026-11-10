import Foundation

/// The playback a ``SleepTimer`` controls. ``AudioEngineSleepTimerControl`` adapts an engine directly; the playback
/// coordinator (#52) should conform itself instead, so that pauses and resumes go through its interruption
/// handling and Now Playing updates.
@MainActor
public protocol SleepTimerPlaybackControl: AnyObject {
    /// Whether audio is playing; an end-of-chapter timer only expires in a paused state at the end of the media.
    var isPlaying: Bool { get }
    /// The timeline time in seconds.
    var currentTime: Double { get }
    /// The playback rate, which converts timeline seconds to wall-clock seconds for an end-of-chapter timer.
    var rate: Double { get }
    /// The loaded timeline; `nil` without media.
    var timeline: PlaybackTimeline? { get }
    /// Whether a seek or load hasn't landed yet; the timer's rewinds yield to it.
    var hasPendingSeek: Bool { get }
    func pause()
    /// Resumes playback after a reset during the grace period.
    func play()
    /// Seeks to a timeline time: back to where the fade began, or a reset's rewind. Returns where playback
    /// landed, or `nil` when the seek didn't complete.
    func seek(to time: Double) async -> Double?
    /// Sets the output volume, `0...1`, for the fade-out. The timer restores `1` when it ends.
    func setVolume(_ volume: Float)
}

/// Controls an engine directly, bypassing interruption handling and Now Playing. ``AudioEngine`` keeps the volume on
/// whichever player is current, including one that replaced a failed player mid-fade.
@MainActor
public final class AudioEngineSleepTimerControl: SleepTimerPlaybackControl {
    private weak var engine: (any AudioEngineProtocol)?

    public init(engine: any AudioEngineProtocol) {
        self.engine = engine
    }

    public var isPlaying: Bool { engine?.state == .playing }
    public var currentTime: Double { engine?.currentTime ?? 0 }
    public var rate: Double { Double(engine?.defaultRate ?? 1) }
    public var timeline: PlaybackTimeline? { engine?.timeline }
    public var hasPendingSeek: Bool { engine?.pendingSeekTarget != nil }

    public func pause() {
        engine?.pause()
    }

    public func play() {
        engine?.play()
    }

    public func seek(to time: Double) async -> Double? {
        guard let engine, await engine.seek(to: time) == .completed else { return nil }
        return engine.currentTime
    }

    public func setVolume(_ volume: Float) {
        engine?.setVolume(volume)
    }
}
