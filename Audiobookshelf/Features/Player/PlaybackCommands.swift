import ABSAppModel
import ABSPlayback
import ABSUI
import SwiftUI

/// The Playback menu (ADR 0004, #82), on a Mac and in the iPad hardware keyboard's ⌘ overlay:
/// Play/Pause (Space), jump back and forward (⌘← and ⌘→), previous and next chapter (⌥⌘← and ⌥⌘→),
/// speed down and up (⌘− and ⌘+), Create Bookmark (⌘B) and a Sleep Timer submenu.
/// ``PlaybackCommandsModel`` has the rules.
///
/// The commands act on the app's one player, not the focused scene's, so they work from any window.
/// They need a ``PlayerViewModel``: until #183 builds one, and passes the account's sleep timer and
/// bookmarks, `player` is the placeholder and every item is disabled.
///
/// Space has no modifier, so a focused text field takes it first and types a space; the menu gets
/// it only when the focused view doesn't handle it. ⌘ shortcuts go to the menu first, so while an
/// item is loaded ⌘← and ⌘→ jump rather than move a text field's insertion point.
struct PlaybackCommands: Commands {
    /// The app's player.
    let player: any PlayerSlotState
    /// The player's sleep timer; `nil` until #183 installs one.
    var sleepTimer: SleepTimer?
    /// The signed-in account's bookmarks; `nil` until #183 passes them.
    var bookmarks: BookmarkStore?

    var body: some Commands {
        CommandMenu(Text(verbatim: L10n.string("HeaderPlayback"))) {
            PlaybackMenu(
                model: PlaybackCommandsModel(
                    player: player as? PlayerViewModel, sleepTimer: sleepTimer, bookmarks: bookmarks))
        }
    }
}

/// The menu's items. Each is its own view, so it updates as the player changes, and the ones that
/// read the playback time (next chapter, Create Bookmark, End of Chapter) redraw alone every tick.
private struct PlaybackMenu: View {
    let model: PlaybackCommandsModel

    var body: some View {
        PlaybackMenuItem(command: .playPause, model: model)
        Divider()
        PlaybackMenuItem(command: .jumpBackward, model: model)
        PlaybackMenuItem(command: .jumpForward, model: model)
        PlaybackMenuItem(command: .previousChapter, model: model)
        PlaybackMenuItem(command: .nextChapter, model: model)
        Divider()
        PlaybackMenuItem(command: .speedDown, model: model)
        PlaybackMenuItem(command: .speedUp, model: model)
        Divider()
        PlaybackMenuItem(command: .addBookmark, model: model)
        Menu {
            ForEach(SleepTimerPanelModel.presetMinutes, id: \.self) { minutes in
                SleepTimerMenuItem(command: .minutes(minutes), model: model)
            }
            Divider()
            SleepTimerMenuItem(command: .endOfChapter, model: model)
            Divider()
            SleepTimerMenuItem(command: .cancel, model: model)
        } label: {
            Text(verbatim: L10n.string("HeaderSleepTimer"))
        }
    }
}

private struct PlaybackMenuItem: View {
    let command: PlaybackCommand
    let model: PlaybackCommandsModel

    var body: some View {
        // Only Play/Pause reads the play state, so the other items don't redraw on play and pause.
        let showsPause = command == .playPause && model.showsPause
        Button {
            Task { await model.perform(command) }
        } label: {
            Text(verbatim: L10n.string(command.titleKey(showsPause: showsPause)))
        }
        .keyboardShortcut(command.shortcut)
        .disabled(!model.isEnabled(command))
    }
}

private struct SleepTimerMenuItem: View {
    let command: SleepTimerCommand
    let model: PlaybackCommandsModel
    @Environment(\.locale) private var locale

    var body: some View {
        Button {
            model.perform(command)
        } label: {
            Text(verbatim: command.title(locale: locale))
        }
        .disabled(!model.isEnabled(command))
    }
}

extension PlaybackCommand {
    /// The key of the item's title in the string catalog; Play/Pause reads Pause while play is
    /// requested, as the player's button shows.
    func titleKey(showsPause: Bool) -> String {
        switch self {
        case .playPause: showsPause ? "ButtonPause" : "ButtonPlay"
        case .jumpBackward: "ButtonJumpBackward"
        case .jumpForward: "ButtonJumpForward"
        case .previousChapter: "ButtonPreviousChapter"
        case .nextChapter: "ButtonNextChapter"
        case .speedUp: "ButtonIncreaseSpeed"
        case .speedDown: "ButtonDecreaseSpeed"
        case .addBookmark: "ButtonCreateBookmark"
        }
    }

    /// Space for Play/Pause, ⌘← and ⌘→ to jump and ⌘B for a bookmark, as #82 asks; ⌥⌘← and ⌥⌘→ for
    /// chapters; ⌘− and ⌘+ for speed, as in the speed sheet.
    var shortcut: KeyboardShortcut {
        switch self {
        case .playPause: KeyboardShortcut(.space, modifiers: [])
        case .jumpBackward: KeyboardShortcut(.leftArrow)
        case .jumpForward: KeyboardShortcut(.rightArrow)
        case .previousChapter: KeyboardShortcut(.leftArrow, modifiers: [.option, .command])
        case .nextChapter: KeyboardShortcut(.rightArrow, modifiers: [.option, .command])
        case .speedUp: KeyboardShortcut("+")
        case .speedDown: KeyboardShortcut("-")
        case .addBookmark: KeyboardShortcut("b")
        }
    }
}

extension SleepTimerCommand {
    /// The item's title: the preset's length in words, such as "15 minutes", End of Chapter or
    /// Cancel Timer.
    func title(locale: Locale) -> String {
        switch self {
        case .minutes(let minutes): MinutesFormatting.string(minutes: minutes, spoken: true, locale: locale)
        case .endOfChapter: L10n.string("LabelEndOfChapter", locale: locale)
        case .cancel: L10n.string("ButtonCancelTimer", locale: locale)
        }
    }
}
