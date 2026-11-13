import ABSAppModel
import ABSUI
import SwiftUI
import Testing

@testable import Audiobookshelf

@Suite struct PlaybackCommandsTests {
    @Test func shortcutsMatchIssue() {
        #expect(PlaybackCommand.playPause.shortcut == KeyboardShortcut(.space, modifiers: []))
        #expect(PlaybackCommand.jumpBackward.shortcut == KeyboardShortcut(.leftArrow, modifiers: .command))
        #expect(PlaybackCommand.jumpForward.shortcut == KeyboardShortcut(.rightArrow, modifiers: .command))
        #expect(
            PlaybackCommand.previousChapter.shortcut == KeyboardShortcut(.leftArrow, modifiers: [.option, .command]))
        #expect(PlaybackCommand.nextChapter.shortcut == KeyboardShortcut(.rightArrow, modifiers: [.option, .command]))
        #expect(PlaybackCommand.speedUp.shortcut == KeyboardShortcut("+", modifiers: .command))
        #expect(PlaybackCommand.speedDown.shortcut == KeyboardShortcut("-", modifiers: .command))
        #expect(PlaybackCommand.addBookmark.shortcut == KeyboardShortcut("b", modifiers: .command))
    }

    @Test func shortcutsAreDistinctFromGoMenu() {
        let playback = PlaybackCommand.allCases.map(\.shortcut)
        #expect(Set(playback).count == playback.count)
        #expect(Set(GoCommand.allCases.map(\.shortcut)).isDisjoint(with: playback))
    }

    @Test func playPauseReadsPauseWhilePlayIsRequested() {
        #expect(PlaybackCommand.playPause.titleKey(showsPause: false) == "ButtonPlay")
        #expect(PlaybackCommand.playPause.titleKey(showsPause: true) == "ButtonPause")
        #expect(PlaybackCommand.nextChapter.titleKey(showsPause: true) == "ButtonNextChapter")
    }

    @Test func sleepTimerTitles() {
        let locale = Locale(identifier: "en_US")
        #expect(SleepTimerCommand.minutes(15).title(locale: locale) == "15 minutes")
        #expect(SleepTimerCommand.endOfChapter.title(locale: locale) == "End of Chapter")
        #expect(SleepTimerCommand.cancel.title(locale: locale) == "Cancel Timer")
    }

    @MainActor
    @Test func failedBookmarkShowsTheSheetsMessage() {
        #expect(PlaybackCommandFailure.addBookmark.messageKey == "ToastBookmarkCreateFailed")

        let alert = PlaybackCommandAlert()
        #expect(!alert.isPresented)
        alert.show(.addBookmark)
        #expect(alert.isPresented)
        #expect(alert.failure == .addBookmark)
    }

    @Test(
        arguments: [
            "HeaderPlayback", "HeaderSleepTimer", "LabelEndOfChapter", "ButtonCancelTimer", "ButtonPause",
            PlaybackCommandFailure.addBookmark.messageKey,
        ] + PlaybackCommand.allCases.map { $0.titleKey(showsPause: false) })
    func menuStringsResolve(key: String) {
        #expect(L10n.string(key) != key, "\(key) is missing from the catalog")
    }
}
