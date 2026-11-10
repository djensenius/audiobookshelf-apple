import ABSCore
import Foundation
import SwiftUI
import Testing

@testable import ABSUI

@Suite struct DesignSystemTests {
    @Test func hapticMapping() {
        #expect(HapticFeedback.off.sensoryFeedback == nil)
        #expect(HapticFeedback.light.sensoryFeedback == .impact(weight: .light))
        #expect(HapticFeedback.medium.sensoryFeedback == .impact(weight: .medium))
        #expect(HapticFeedback.heavy.sensoryFeedback == .impact(weight: .heavy))
    }

    @Test func themeColorScheme() {
        #expect(AppTheme.system.colorScheme == nil)
        #expect(AppTheme.light.colorScheme == .light)
        #expect(AppTheme.dark.colorScheme == .dark)
        #expect(AppTheme.black.colorScheme == .dark)
        #expect(AppTheme.allCases.filter(\.usesTrueBlack) == [.black])
    }

    @Test func blackThemeUsesTrueBlackBackground() {
        #expect(ABSColor.background(for: .black) == .black)
        #expect(ABSColor.surface(for: .black) == .black)
        #expect(ABSColor.background(for: .dark) != .black)
    }

    @Test func timestampMatchesLegacy() {
        #expect(DurationStyle.timestamp.string(245) == "4:05")
        #expect(DurationStyle.timestamp.string(3723.9) == "1:02:03")
    }

    @Test func elapsedMatchesLegacy() {
        let english = Locale(identifier: "en_US")
        let elapsed = DurationStyle.elapsed()
        #expect(elapsed.string(93_784, locale: english) == "1d 2h 3m 4s")
        #expect(elapsed.string(3_600, locale: english) == "1h")
        #expect(elapsed.string(65.7, locale: english) == "1m 5s")
        #expect(DurationStyle.elapsed(useDays: false).string(93_784, locale: english) == "26h 3m 4s")
        #expect(DurationStyle.elapsed(showSeconds: false).string(3_690, locale: english) == "1h 2m")
        #expect(DurationStyle.elapsed(showSeconds: false).string(3_660 + 29, locale: english) == "1h 1m")
    }

    @Test func durationAccessibilityIsSpokenInWords() {
        let english = Locale(identifier: "en_US")
        #expect(DurationStyle.timestamp.accessibilityString(3_723, locale: english) == "1 hour, 2 minutes, 3 seconds")
        #expect(DurationStyle.elapsed().accessibilityString(90_000, locale: english) == "1 day, 1 hour")
    }

    @Test func progressIsClamped() {
        #expect(clampedProgress(-1) == 0)
        #expect(clampedProgress(2) == 1)
        #expect(clampedProgress(.nan) == 0)
        #expect(progressAccessibilityValue(0.424, locale: Locale(identifier: "en_US")) == "42%")
    }

    @Test func connectionStatusMapping() {
        #expect(ConnectionStatus.offline.messageKey == "MessageNoNetworkConnection")
        #expect(ConnectionStatus.connecting.messageKey == "MessageAttemptingServerConnection")
        #expect(ConnectionStatus.serverUnreachable.messageKey == "MessageSocketNotConnected")
        #expect(
            ConnectionStatus.connected(cellular: true, metered: true).messageKey
                == "MessageSocketConnectedOverMeteredCellular"
        )
        #expect(
            ConnectionStatus.connected(cellular: false, metered: false).messageKey
                == "MessageSocketConnectedOverUnmeteredWifi"
        )
        #expect(ConnectionStatus.offline.systemImage == "wifi.slash")
        #expect(ConnectionStatus.connected(cellular: false, metered: false).systemImage == "checkmark.icloud")
    }

    @Test func componentStringsExist() {
        let english = Locale(identifier: "en")
        let keys = [
            "LabelExplicit", "LabelAbridged", "ButtonRetry", "MessageLoading", "ButtonReadMore", "ButtonReadLess",
            "LabelProgress", "LabelFinished", "HeaderConnectionStatus",
            "MessageSocketConnectedOverUnmeteredCellular", "MessageSocketConnectedOverMeteredWifi",
        ]
        for key in keys {
            #expect(L10n.string(key, locale: english) != key, "\(key)")
        }
        #expect(L10n.string("LabelAbridged", locale: english) == "Abridged")
        #expect(L10n.string("ButtonRetry", locale: english) == "Retry")
    }
}
