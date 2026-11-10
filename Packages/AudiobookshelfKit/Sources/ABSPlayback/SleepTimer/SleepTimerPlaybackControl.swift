import Foundation

/// The playback a ``SleepTimer`` controls. ``AudioEngineSleepTimerControl`` adapts ``AudioEngine``; the playback
/// coordinator may conform itself so that pauses and resumes go through it.
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
    func pause()
    /// Resumes playback after moving back `seconds` (no move for `0`): shaking during the grace period after expiry.
    func play(rewindingBy seconds: Double)
    /// Sets the output volume, `0...1`, for the fade-out. The timer restores `1` when it ends.
    func setVolume(_ volume: Float)
}

/// Controls an ``AudioEngine`` directly. The volume goes to the engine's player, which only the sleep timer changes.
@MainActor
public final class AudioEngineSleepTimerControl: SleepTimerPlaybackControl {
    private weak var engine: AudioEngine?

    public init(engine: AudioEngine) {
        self.engine = engine
    }

    public var isPlaying: Bool { engine?.state == .playing }
    public var currentTime: Double { engine?.currentTime ?? 0 }
    public var rate: Double { Double(engine?.defaultRate ?? 1) }
    public var timeline: PlaybackTimeline? { engine?.timeline }

    public func pause() {
        engine?.pause()
    }

    public func play(rewindingBy seconds: Double) {
        guard let engine else { return }
        guard seconds > 0, let timeline = engine.timeline else {
            engine.play()
            return
        }
        let target = timeline.jumpBackward(from: engine.currentTime, by: seconds)
        Task { [weak engine] in
            guard let engine else { return }
            _ = await engine.seek(to: target)
            engine.play()
        }
    }

    public func setVolume(_ volume: Float) {
        engine?.player.volume = min(max(volume, 0), 1)
    }
}
