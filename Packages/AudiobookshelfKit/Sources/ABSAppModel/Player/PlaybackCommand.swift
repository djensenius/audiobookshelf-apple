import ABSPlayback
import Foundation

/// An item of the Playback menu (ADR 0004, #82), which acts on the app's one player, so it works
/// from any window. ``PlaybackCommandsModel`` has the rules, so they are testable.
public enum PlaybackCommand: Hashable, CaseIterable, Sendable {
    /// Pauses while play is requested, else resumes (``PlayerViewModel/togglePlayPause()``).
    case playPause
    /// Jumps by the interval from Settings (``PlayerViewModel/jumpBackward()``).
    case jumpBackward
    /// Jumps by the interval from Settings (``PlayerViewModel/jumpForward()``).
    case jumpForward
    /// ``PlayerViewModel/previousChapter()``: restarts the chapter, or goes to the previous one.
    case previousChapter
    /// ``PlayerViewModel/nextChapter()``.
    case nextChapter
    /// One ``PlaybackSpeed`` step up (``PlayerViewModel/stepRate(up:)``).
    case speedUp
    /// One ``PlaybackSpeed`` step down.
    case speedDown
    /// Adds a bookmark at the current second, titled with the date and time (D9), as the bookmarks
    /// sheet's Create Bookmark does with an empty title.
    case addBookmark
}

/// A Playback menu command that failed, for the menu to report.
public enum PlaybackCommandFailure: Hashable, Sendable {
    /// Add Bookmark's request failed, and the store rolled the bookmark back.
    case addBookmark
}

/// An item of the Playback menu's Sleep Timer submenu.
public enum SleepTimerCommand: Hashable, Sendable {
    /// Starts a timer of this many minutes, replacing any running one.
    case minutes(Int)
    /// Starts a timer that pauses at the end of the chapter.
    case endOfChapter
    /// Cancels the running timer, or ends the grace period of one that expired.
    case cancel
}

/// The Playback menu's rules (ADR 0004, #82) over the app's player, its sleep timer and the
/// signed-in account's bookmarks; each is `nil` until the app has one. Holds no state, so the menu
/// makes one per body, and reads the player, timer and store through it, so it updates with them.
///
/// - Nothing is enabled without a ``PlayerViewModel``, nor without an item
///   (``PlayerViewModel/hasSession``) but Cancel Timer; signing out leaves the account's playback
///   idle, so it's covered too.
/// - Otherwise each command is enabled when its control in the player is: the chapter and speed
///   commands when they would move, and Add Bookmark when the bookmarks sheet's Create Bookmark
///   would be enabled (``PlayerBookmarksModel/canCreate``).
/// - ``perform(_:)`` does nothing when the command isn't enabled, so a shortcut that fires before
///   the menu has updated can't act on a state the menu didn't offer. It returns a failed Add
///   Bookmark, for the menu to report as the bookmarks sheet does.
///
/// The next chapter, End of Chapter and Add Bookmark rules read the playback time, so read them only
/// in small leaf views.
@MainActor
public struct PlaybackCommandsModel {
    public let player: PlayerViewModel?
    public let sleepTimer: SleepTimer?
    public let bookmarks: BookmarkStore?

    public init(player: PlayerViewModel?, sleepTimer: SleepTimer? = nil, bookmarks: BookmarkStore? = nil) {
        self.player = player
        self.sleepTimer = sleepTimer
        self.bookmarks = bookmarks
    }

    /// The player, when it has an item; `nil` otherwise, when no command is enabled.
    private var activePlayer: PlayerViewModel? {
        guard let player, player.hasSession else { return nil }
        return player
    }

    /// Whether Play/Pause reads Pause: while play is requested, as the player's button shows.
    public var showsPause: Bool { player?.showsPause ?? false }

    // MARK: Transport

    /// Whether `command` is enabled now.
    public func isEnabled(_ command: PlaybackCommand) -> Bool {
        guard let player = activePlayer else { return false }
        switch command {
        case .playPause, .jumpBackward, .jumpForward: return true
        case .previousChapter: return player.hasPreviousChapter
        case .nextChapter: return player.hasNextChapter
        case .speedUp: return player.canStepRate(up: true)
        case .speedDown: return player.canStepRate(up: false)
        case .addBookmark: return bookmarksModel(player)?.canCreate ?? false
        }
    }

    /// Runs `command` on the player; does nothing when it isn't enabled.
    /// - Returns: ``PlaybackCommandFailure/addBookmark`` when Add Bookmark fails, after the store
    ///   has rolled the bookmark back; `nil` otherwise, and when its request was cancelled.
    @discardableResult
    public func perform(_ command: PlaybackCommand) async -> PlaybackCommandFailure? {
        guard isEnabled(command), let player = activePlayer else { return nil }
        switch command {
        case .playPause: await player.togglePlayPause()
        case .jumpBackward: await player.jumpBackward()
        case .jumpForward: await player.jumpForward()
        case .previousChapter: await player.previousChapter()
        case .nextChapter: await player.nextChapter()
        case .speedUp: player.stepRate(up: true)
        case .speedDown: player.stepRate(up: false)
        case .addBookmark:
            guard let model = bookmarksModel(player), let itemID = model.currentItemID else { return nil }
            do {
                try await model.create(title: "", itemID: itemID, at: model.creationTime)
            } catch is CancellationError {
            } catch {
                return .addBookmark
            }
        }
        return nil
    }

    private func bookmarksModel(_ player: PlayerViewModel) -> PlayerBookmarksModel? {
        bookmarks.map { PlayerBookmarksModel(player: player, store: $0) }
    }

    // MARK: Sleep timer

    /// Whether `command` is enabled now: starting a timer needs an item, and End of Chapter a chapter
    /// playing (``SleepTimerPanelModel/offersEndOfChapter``) that ends after the playback position.
    /// At the end of the media the last chapter is still playing but has no end ahead, so the timer
    /// can't start; the sheet says so (D16), and the menu disables the item instead. Cancel needs a
    /// timer running or in its grace period, and isn't offered for the automatic timer, whose cancel
    /// the sleep timer sheet confirms first (D18).
    public func isEnabled(_ command: SleepTimerCommand) -> Bool {
        guard let panel = sleepTimerPanel else { return false }
        switch command {
        case .minutes: return activePlayer != nil
        case .endOfChapter:
            guard let player = activePlayer else { return false }
            return hasChapterEndAhead(player)
        case .cancel: return panel.state != .idle && !panel.needsCancelConfirmation
        }
    }

    /// Runs `command` on the sleep timer; does nothing when it isn't enabled.
    public func perform(_ command: SleepTimerCommand) {
        guard isEnabled(command), let panel = sleepTimerPanel else { return }
        switch command {
        case .minutes(let minutes): panel.start(minutes: minutes)
        case .endOfChapter: panel.startEndOfChapter()
        case .cancel: panel.cancel()
        }
    }

    /// The sleep timer sheet's model; `nil` without a timer or a player.
    private var sleepTimerPanel: SleepTimerPanelModel? {
        guard let sleepTimer, let player else { return nil }
        return SleepTimerPanelModel(timer: sleepTimer, player: player)
    }

    /// Whether the chapter playing ends after the playback position, as the sleep timer needs to start
    /// at end of chapter. Reads the playback time.
    private func hasChapterEndAhead(_ player: PlayerViewModel) -> Bool {
        let time = player.playback.currentTime
        guard let end = player.playback.timeline?.endOfChapter(at: time) else { return false }
        return end > time
    }
}
