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
/// The account's sleep timer and bookmarks come from the playback participant (#183), read in
/// ``body`` so the menu follows each session's; between sessions those items are disabled.
///
/// Space has no modifier, so a focused text field takes it first and types a space; the menu gets
/// it only when the focused view doesn't handle it. ⌘ shortcuts go to the menu first, so while an
/// item is loaded ⌘← and ⌘→ jump rather than move a text field's insertion point.
///
/// A failed Create Bookmark shows an alert in the window it was chosen from, through that window's
/// ``PlaybackCommandAlert``; with no window focused there is nowhere to show it.
struct PlaybackCommands: Commands {
    /// The app's player.
    let player: any PlayerSlotState
    /// The signed-in account's playback: its sleep timer and bookmarks. `nil` without a data stack.
    var participant: PlaybackSessionParticipant?
    /// The focused window's alert, for a command that fails.
    @FocusedValue(PlaybackCommandAlert.self) private var alert: PlaybackCommandAlert?

    var body: some Commands {
        CommandMenu(Text(verbatim: L10n.string("HeaderPlayback"))) {
            PlaybackMenu(model: model, alert: alert)
        }
    }

    /// The menu's rules over the current session's sleep timer and bookmarks.
    var model: PlaybackCommandsModel {
        PlaybackCommandsModel(
            player: player as? PlayerViewModel, sleepTimer: participant?.sleepTimer,
            bookmarks: participant?.bookmarks)
    }
}

/// The menu's items. Each is its own view, so it updates as the player changes, and the ones that
/// read the playback time (the chapter commands, Create Bookmark, End of Chapter) redraw alone
/// every tick.
private struct PlaybackMenu: View {
    let model: PlaybackCommandsModel
    let alert: PlaybackCommandAlert?

    var body: some View {
        PlaybackMenuItem(command: .playPause, model: model, alert: alert)
        Divider()
        PlaybackMenuItem(command: .jumpBackward, model: model, alert: alert)
        PlaybackMenuItem(command: .jumpForward, model: model, alert: alert)
        PlaybackMenuItem(command: .previousChapter, model: model, alert: alert)
        PlaybackMenuItem(command: .nextChapter, model: model, alert: alert)
        Divider()
        PlaybackMenuItem(command: .speedDown, model: model, alert: alert)
        PlaybackMenuItem(command: .speedUp, model: model, alert: alert)
        Divider()
        PlaybackMenuItem(command: .addBookmark, model: model, alert: alert)
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
    /// Where a failure shows: the window the command was chosen from.
    let alert: PlaybackCommandAlert?

    var body: some View {
        // Only Play/Pause reads the play state, so the other items don't redraw on play and pause.
        let showsPause = command == .playPause && model.showsPause
        Button {
            Task {
                if let failure = await model.perform(command) { alert?.show(failure) }
            }
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

/// A window's alert for the Playback menu's failures. The menu acts on the app's one player, not on a
/// window, so each signed-in window publishes one (``SwiftUICore/View/playbackCommandAlert()``) and the
/// menu shows a failure in the window it was chosen from.
@MainActor
@Observable
final class PlaybackCommandAlert {
    /// The last failure; kept while the alert closes so its title doesn't go blank.
    private(set) var failure: PlaybackCommandFailure?
    var isPresented = false

    func show(_ failure: PlaybackCommandFailure) {
        self.failure = failure
        isPresented = true
    }
}

extension View {
    /// Shows the Playback menu's failures in this window, as the bookmarks sheet shows its own.
    func playbackCommandAlert() -> some View {
        modifier(PlaybackCommandAlertModifier())
    }
}

private struct PlaybackCommandAlertModifier: ViewModifier {
    @State private var alert = PlaybackCommandAlert()

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(alert)
            .alert(
                Text(verbatim: alert.failure.map { L10n.string($0.messageKey) } ?? ""),
                isPresented: $alert.isPresented, presenting: alert.failure
            ) { _ in
                Button {
                } label: {
                    Text(verbatim: L10n.string("ButtonOk"))
                }
            }
    }
}

extension PlaybackCommandFailure {
    /// The key of the alert's message: the bookmarks sheet's, from the legacy toast.
    var messageKey: String {
        switch self {
        case .addBookmark: BookmarkFailure.create.messageKey
        }
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
