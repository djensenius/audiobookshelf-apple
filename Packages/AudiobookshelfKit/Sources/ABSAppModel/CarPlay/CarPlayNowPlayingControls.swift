import ABSPlayback
import Foundation

/// What CarPlay's Now Playing buttons show (#81). Changes only when a button's look or the Up Next
/// button does, not as playback ticks, so the delegate can rebuild the buttons on each change.
public struct CarPlayNowPlayingButtons: Sendable, Hashable {
    /// The player's rate, for the rate button.
    public var rate: Double
    /// Whether a sleep timer runs: the sleep timer button shows as selected.
    public var isSleepTimerActive: Bool
    /// Whether the item has chapters: the chapters button is enabled.
    public var hasChapters: Bool
    /// What the Up Next button opens; `nil` disables it.
    public var upNext: CarPlayUpNext?

    public init(rate: Double, isSleepTimerActive: Bool, hasChapters: Bool, upNext: CarPlayUpNext?) {
        self.rate = rate
        self.isSleepTimerActive = isSleepTimerActive
        self.hasChapters = hasChapters
        self.upNext = upNext
    }
}

/// What Now Playing's Up Next button opens.
public enum CarPlayUpNext: Sendable, Hashable {
    /// The play queue, when it has items.
    case queue
    /// The item's chapters, when the queue is empty.
    case chapters
}

/// What a tap on the sleep timer button does.
public enum CarPlaySleepTimerAction: Sendable, Hashable {
    case start(SleepTimerMode)
    case cancel
}

/// One row of CarPlay's chapter list.
public struct CarPlayChapterRow: Sendable, Hashable, Identifiable {
    public let chapter: PlayerChapterRow
    /// Whether it's the chapter playing now.
    public let isCurrent: Bool

    public var id: Int { chapter.id }
    /// Where a tap seeks: the chapter's start, in media seconds.
    public var seekTarget: Double { chapter.start }
}

/// The pure mapping from playback state to CarPlay's Now Playing buttons and lists (#81).
public enum CarPlayNowPlayingControls {
    /// The rates the rate button cycles through: the list Now Playing offers the system
    /// (``NowPlayingSettings/defaultSupportedRates``), so both agree.
    public static let rates = NowPlayingSettings.defaultSupportedRates
    /// The durations, in minutes, the sleep timer button cycles through before end of chapter and off.
    public static let sleepTimerPresetMinutes = [15, 30, 45, 60]

    /// The rate after `rate` in `rates`: the next larger one, wrapping to the first. A rate between
    /// two goes to the larger one.
    public static func nextRate(after rate: Double, in rates: [Double] = rates) -> Double {
        let sorted = rates.sorted()
        guard let first = sorted.first else { return rate }
        return sorted.first { $0 > rate + PlaybackSpeed.tolerance } ?? first
    }

    /// Whether the sleep timer button shows as selected: while a timer, manual or automatic, runs.
    public static func isSleepTimerActive(_ mode: SleepTimerMode?) -> Bool {
        mode != nil
    }

    /// What a tap on the sleep timer button does, given the running timer's `mode`: off starts the
    /// first preset, a duration starts the next longer preset, past the last one end of chapter
    /// (when `offersEndOfChapter`), and end of chapter turns it off. A duration with time added
    /// moves on to the next preset longer than it.
    public static func sleepTimerAction(
        after mode: SleepTimerMode?, offersEndOfChapter: Bool, presetMinutes: [Int] = sleepTimerPresetMinutes
    ) -> CarPlaySleepTimerAction {
        let presets = presetMinutes.sorted().map { TimeInterval($0) * 60 }
        let next: TimeInterval?
        switch mode {
        case nil: next = presets.first
        case .duration(let length): next = presets.first { $0 > length + 0.5 }
        case .endOfChapter: return .cancel
        }
        if let next { return .start(.duration(next)) }
        return offersEndOfChapter ? .start(.endOfChapter) : .cancel
    }

    /// What Up Next opens: the queue when it has items, else the chapters, else nothing.
    public static func upNext(queueCount: Int, hasChapters: Bool) -> CarPlayUpNext? {
        if queueCount > 0 { return .queue }
        return hasChapters ? .chapters : nil
    }

    /// Whether a play from a list over Now Playing returns to Now Playing: only once it started.
    /// A blocked or failed play stays, so the root model's alert shows over the list.
    public static func returnsToNowPlaying(after outcome: CarPlayPlayOutcome) -> Bool {
        outcome == .started
    }

    /// The chapter list's rows, at most `limit`: all of them when they fit, otherwise a window
    /// that starts one before the current chapter, so it and the next ones show.
    public static func chapterRows(_ chapters: [PlayerChapterRow], currentIndex: Int?, limit: Int)
        -> [CarPlayChapterRow]
    {
        let limit = max(1, limit)
        var start = 0
        if chapters.count > limit, let currentIndex {
            start = max(0, min(currentIndex - 1, chapters.count - limit))
        }
        return chapters.dropFirst(start).prefix(limit).map {
            CarPlayChapterRow(chapter: $0, isCurrent: $0.id == currentIndex)
        }
    }
}

/// CarPlay's Now Playing buttons and lists over the app's player (#81): the rate, sleep timer and
/// chapters buttons and what Up Next opens. Like ``SleepTimerPanelModel`` it holds no state:
/// ``buttons``, ``chapters`` and ``queueRows`` read the player, the timer and the queue, so
/// reading them inside `withObservationTracking` follows them.
@MainActor
public final class CarPlayNowPlayingModel {
    private let player: PlayerViewModel
    private let sleepTimer: @MainActor () -> SleepTimer?
    private let queue: @MainActor () -> (any PlaybackQueueReading)?
    private let playQueued: @MainActor (QueueRow) -> Task<CarPlayPlayOutcome, Never>?
    private let chapterLimit: Int

    /// - Parameters:
    ///   - sleepTimer: The current account session's timer, if any.
    ///   - queue: The current account session's queue, if any.
    ///   - playQueued: Plays a queue row through CarPlay's root model, whose outcome and alert it
    ///     shares (``CarPlayRootModel/playQueued(_:)``).
    ///   - chapterLimit: The most rows the chapter list shows (the car's list limit).
    public init(
        player: PlayerViewModel, sleepTimer: @escaping @MainActor () -> SleepTimer?,
        queue: @escaping @MainActor () -> (any PlaybackQueueReading)?,
        playQueued: @escaping @MainActor (QueueRow) -> Task<CarPlayPlayOutcome, Never>?, chapterLimit: Int
    ) {
        self.player = player
        self.sleepTimer = sleepTimer
        self.queue = queue
        self.playQueued = playQueued
        self.chapterLimit = chapterLimit
    }

    /// The buttons' state. Doesn't read the playback time.
    public var buttons: CarPlayNowPlayingButtons {
        let hasChapters = player.hasChapters
        return CarPlayNowPlayingButtons(
            rate: player.rate, isSleepTimerActive: CarPlayNowPlayingControls.isSleepTimerActive(sleepTimer()?.mode),
            hasChapters: hasChapters,
            upNext: CarPlayNowPlayingControls.upNext(queueCount: queue()?.items.count ?? 0, hasChapters: hasChapters))
    }

    /// Sets the next rate of ``CarPlayNowPlayingControls/rates``.
    public func cycleRate() {
        player.setRate(CarPlayNowPlayingControls.nextRate(after: player.rate))
    }

    /// Starts the next sleep timer preset, or turns it off (``CarPlayNowPlayingControls/sleepTimerAction(after:offersEndOfChapter:presetMinutes:)``).
    /// An end-of-chapter timer that can't start turns it off.
    public func cycleSleepTimer() {
        guard let timer = sleepTimer() else { return }
        let playback = player.playback
        let offersEndOfChapter = playback.timeline?.endOfChapter(at: playback.currentTime) != nil
        switch CarPlayNowPlayingControls.sleepTimerAction(after: timer.mode, offersEndOfChapter: offersEndOfChapter) {
        case .start(let mode): if !timer.start(mode) { timer.cancel() }
        case .cancel: timer.cancel()
        }
    }

    /// The chapter list. Reads the playback time, so it changes as playback moves.
    public var chapters: [CarPlayChapterRow] {
        CarPlayNowPlayingControls.chapterRows(
            player.chapters, currentIndex: player.currentChapterIndex, limit: chapterLimit)
    }

    /// Seeks to `row`'s chapter, keeping play or pause.
    public func select(_ row: CarPlayChapterRow) async {
        await player.selectChapter(row.chapter)
    }

    /// The queue's rows, in play order, at most the chapter list's limit.
    public var queueRows: [QueueRow] {
        guard let queue = queue() else { return [] }
        return Array(QueueRow.rows(of: queue).prefix(chapterLimit))
    }

    /// Plays `row` from its saved progress; `nil` when nothing can play it.
    @discardableResult
    public func play(_ row: QueueRow) -> Task<CarPlayPlayOutcome, Never>? {
        playQueued(row)
    }
}

/// The one observation loop of a list pushed over Now Playing (#81). A loop re-registers on every
/// change, so each pushed list must end its predecessor's: a loop goes on only while its list is
/// the latest one and still shown.
@MainActor
public final class CarPlayListObservation<List: AnyObject> {
    /// The latest list, while its loop runs.
    public private(set) weak var list: List?

    public init() {}

    /// Makes `list` the observed one; the earlier list's loop stops at its next change.
    public func begin(_ list: List) {
        self.list = list
    }

    /// Stops observing.
    public func end() {
        list = nil
    }

    /// Whether the loop observing `list` observes again: only for the latest list while
    /// `isShown`. A latest list no longer shown ends the observation.
    public func continues(_ list: List, isShown: Bool) -> Bool {
        guard self.list === list else { return false }
        guard isShown else {
            end()
            return false
        }
        return true
    }
}
