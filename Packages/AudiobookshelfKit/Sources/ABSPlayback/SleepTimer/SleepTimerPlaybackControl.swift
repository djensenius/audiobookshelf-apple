import Foundation

/// The playback a ``SleepTimer`` controls. ``PlaybackCoordinator`` conforms so pauses and resumes go through its
/// interruption handling, events and Now Playing updates. ``AudioEngineSleepTimerControl`` is a direct-engine
/// adapter that bypasses the coordinator.
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
    /// Where a seek or load in flight (or an interrupted one, awaiting its retry) will land; `nil` when none. The timer
    /// takes it as the position, so its rewinds yield to a user's seek and follow its own. ``seek(to:)`` must set it
    /// before its first suspension, as ``AudioEngine`` does: the timer reads it as soon as it has started a seek. A
    /// seek kept for its retry keeps the target it was asked for (to within 10 ms), which is how the timer tells it
    /// from a user's seek that superseded it and landed nearby.
    var pendingSeekTarget: Double? { get }
    func pause()
    /// Resumes playback after a reset during the grace period. Returns whether playback was requested: `false` when
    /// it was refused (the audio session won't activate, say), so the timer reopens its grace period.
    @discardableResult
    func play() -> Bool
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
    public var pendingSeekTarget: Double? { engine?.pendingSeekTarget }

    public func pause() {
        engine?.pause()
    }

    @discardableResult
    public func play() -> Bool {
        guard let engine else { return false }
        engine.play()
        return engine.isPlaybackRequested
    }

    public func seek(to time: Double) async -> Double? {
        guard let engine, await engine.seek(to: time) == .completed else { return nil }
        return engine.currentTime
    }

    public func setVolume(_ volume: Float) {
        engine?.setVolume(volume)
    }
}
