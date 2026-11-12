import ABSAppModel
import ABSCore
import ABSPlayback
import Foundation

/// The preview playback drives a sleep timer too, as the coordinator does in the app.
extension PreviewPlaybackControl: SleepTimerPlaybackControl {
    var pendingSeekTarget: Double? { nil }

    func play() {
        isPlaybackRequested = true
        isPlaying = true
    }

    func setVolume(_ volume: Float) {}
}

/// A player and a sleep timer over one ``PreviewPlaybackControl``, playing the preview book in its
/// second chapter, with the timer in `state`. The timer counts down in real time.
@MainActor
struct SleepTimerPreviewFixture {
    enum State {
        case idle
        /// 25 minutes.
        case running
        /// The auto sleep timer's 15 minutes, its window spanning the day.
        case automatic
        case endOfChapter
        /// A one-second timer that expires and can then restart for the grace period.
        case gracePeriod
    }

    let model: PlayerViewModel
    let timer: SleepTimer

    init(_ state: State) {
        let control = PreviewPlaybackControl(at: 4_000, playing: state != .idle)
        let suiteName = "SleepTimerPreview"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        var options = SleepTimerOptions(fadesOut: false)
        if state == .automatic, let start = AutoSleepPolicy.TimeOfDay(hour: 0, minute: 0),
            let end = AutoSleepPolicy.TimeOfDay(hour: 23, minute: 59)
        {
            options.autoSleep = AutoSleepPolicy(start: start, end: end, mode: .duration(15 * 60))
        }
        timer = SleepTimer(control: control, options: options)
        model = PlayerViewModel(playback: control, settings: AppSettings(defaults: defaults))
        switch state {
        case .idle: break
        case .running: timer.start(.duration(25 * 60))
        case .automatic: _ = timer.playbackWillStart()
        case .endOfChapter: timer.start(.endOfChapter)
        case .gracePeriod: timer.start(.duration(1))
        }
    }
}
