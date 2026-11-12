import ABSAppModel
import ABSPlayback
import ABSUI
import SwiftUI

extension EnvironmentValues {
    /// The sleep timer for the player, or `nil` until the app installs one (#183): then the
    /// toolbar's sleep timer button is disabled.
    @Entry var sleepTimer: SleepTimer? = nil
}

/// The toolbar slot's text: the moon when idle and the time left while a timer runs (D19).
struct SleepTimerSlotPresentation: Equatable {
    /// The countdown, such as `14:59`; `nil` when no timer runs.
    let countdownText: String?
    /// Whether the running timer started automatically, marked with a filled moon.
    let isAutomatic: Bool
    let accessibilityLabel: String
    /// "15 minutes remaining", by the minute until the last minute, so VoiceOver doesn't read a new
    /// value every second; `nil` when no timer runs.
    let accessibilityValue: String?

    init(remaining: TimeInterval?, isAutomatic: Bool, locale: Locale) {
        accessibilityLabel = L10n.string("LabelSleepTimer", locale: locale)
        guard let remaining else {
            countdownText = nil
            self.isAutomatic = false
            accessibilityValue = nil
            return
        }
        countdownText = Self.countdown(remaining, locale: locale)
        self.isAutomatic = isAutomatic
        let value = L10n.string("LabelTimeRemaining", Self.spokenRemaining(remaining, locale: locale), locale: locale)
        accessibilityValue = isAutomatic ? "\(L10n.string("LabelAutoSleepTimer", locale: locale)), \(value)" : value
    }

    /// The time left as a timestamp, rounded up so a 15-minute timer starts at `15:00`.
    static func countdown(_ remaining: TimeInterval, locale: Locale) -> String {
        DurationStyle.timestamp.string(remaining.rounded(.up), locale: locale)
    }

    /// The time left in words: whole minutes, rounded up, above a minute, and seconds below.
    static func spokenRemaining(_ remaining: TimeInterval, locale: Locale) -> String {
        let seconds = max(remaining, 0)
        let rounded = seconds > 60 ? (seconds / 60).rounded(.up) * 60 : seconds.rounded(.up)
        return DurationStyle.timestamp.accessibilityString(rounded, locale: locale)
    }
}

/// The toolbar's sleep timer button: the moon when idle, the countdown while a timer runs (a
/// filled moon before it for the automatic timer). Disabled without a timer. It reads the
/// countdown itself, so only this button redraws every tick.
struct SleepTimerSlot: View {
    let model: PlayerViewModel
    @Binding var sheet: PlayerSheet?
    @Environment(\.sleepTimer) private var timer
    @Environment(\.locale) private var locale

    var body: some View {
        let presentation = SleepTimerSlotPresentation(
            remaining: timer?.remaining, isAutomatic: timer?.isAutomatic ?? false, locale: locale)
        Button {
            sheet = .sleepTimer
        } label: {
            if let countdown = presentation.countdownText {
                HStack(spacing: ABSSpacing.xSmall) {
                    if presentation.isAutomatic {
                        Image(systemName: "moon.zzz.fill")
                    }
                    Text(verbatim: countdown)
                        .monospacedDigit()
                }
            } else {
                Label {
                    Text(verbatim: presentation.accessibilityLabel)
                } icon: {
                    Image(systemName: "moon.zzz")
                }
            }
        }
        .help(Text(verbatim: presentation.accessibilityLabel))
        .accessibilityLabel(Text(verbatim: presentation.accessibilityLabel))
        .accessibilityValue(Text(verbatim: presentation.accessibilityValue ?? ""))
        .accessibilityAddTraits(presentation.countdownText == nil ? [] : .updatesFrequently)
        .disabled(timer == nil)
    }
}

/// The sleep timer sheet (port of `SleepTimerModal.vue`). Idle, it lists the lengths to start;
/// while a timer runs, the time left with −/+ 5 minutes and Cancel Timer (Disable Auto Timer, after
/// a confirmation, for the automatic timer). For two minutes after the timer paused playback, it
/// offers to restart it.
struct SleepTimerSheet: View {
    let model: PlayerViewModel
    let close: () -> Void
    @Environment(\.sleepTimer) private var timer

    var body: some View {
        let title = L10n.string("HeaderSleepTimer")
        Group {
            if let timer {
                SleepTimerPanel(panel: SleepTimerPanelModel(timer: timer, player: model), close: close)
            } else {
                ContentUnavailableView {
                    Label {
                        Text(verbatim: title)
                    } icon: {
                        Image(systemName: "moon.zzz")
                    }
                }
            }
        }
        .playerSheetStyle(title: title, onDone: close)
    }
}

/// The sheet's list. It reads the panel's state, which doesn't change as the timer ticks; the
/// countdown and the End of Chapter row read what does.
private struct SleepTimerPanel: View {
    let panel: SleepTimerPanelModel
    let close: () -> Void
    @State private var confirmsCancel = false
    @State private var showsEndOfChapterFailure = false
    @Environment(\.locale) private var locale

    var body: some View {
        let state = panel.state
        List {
            switch state {
            case .idle:
                lengths
            case .restartable:
                Section {
                    Text(
                        verbatim: L10n.string(
                            "MessageSleepTimerCanRestart",
                            MinutesFormatting.string(
                                minutes: Int(SleepTimer.gracePeriod / 60), spoken: true, locale: locale)))
                    Button {
                        panel.restart()
                        close()
                    } label: {
                        Label {
                            Text(verbatim: L10n.string("ButtonRestartSleepTimer"))
                        } icon: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                    }
                } footer: {
                    shakeHint
                }
                lengths
            case .running(let isAutomatic, let isEndOfChapter):
                Section {
                    if isAutomatic {
                        Label {
                            Text(verbatim: L10n.string("LabelAutoSleepTimer"))
                        } icon: {
                            Image(systemName: "moon.zzz.fill")
                        }
                    }
                    if isEndOfChapter {
                        Label {
                            Text(verbatim: L10n.string("LabelEndOfChapter"))
                        } icon: {
                            Image(systemName: "book.pages")
                        }
                    }
                    adjustments
                } footer: {
                    shakeHint
                }
                Section {
                    Button(role: .destructive) {
                        if panel.needsCancelConfirmation {
                            confirmsCancel = true
                        } else {
                            panel.cancel()
                            close()
                        }
                    } label: {
                        Text(verbatim: L10n.string(isAutomatic ? "ButtonDisableAutoTimer" : "ButtonCancelTimer"))
                    }
                }
            }
        }
        .alert(Text(verbatim: L10n.string("HeaderConfirm")), isPresented: $confirmsCancel) {
            Button(L10n.string("ButtonDisableAutoTimer"), role: .destructive) {
                panel.cancel()
                close()
            }
            Button(L10n.string("ButtonCancel"), role: .cancel) {}
        } message: {
            Text(verbatim: L10n.string("MessageConfirmDisableAutoTimer"))
        }
        .alert(Text(verbatim: L10n.string("LabelEndOfChapter")), isPresented: $showsEndOfChapterFailure) {
            Button(L10n.string("ButtonOk")) {}
        } message: {
            Text(verbatim: L10n.string("MessageSleepTimerEndOfChapterUnavailable"))
        }
    }

    private var lengths: some View {
        SleepTimerLengthPicker(offersEndOfChapter: { panel.offersEndOfChapter }) { choice in
            switch choice {
            case .minutes(let minutes):
                panel.start(minutes: minutes)
                close()
            case .endOfChapter:
                // D16: say why rather than hide the option.
                if panel.startEndOfChapter() { close() } else { showsEndOfChapterFailure = true }
            case .custom:
                break
            }
        }
    }

    /// −5 min, the countdown and +5 min, stacked at accessibility sizes.
    private var adjustments: some View {
        let minutes = MinutesFormatting.string(minutes: Int(SleepTimerPanelModel.adjustment / 60), locale: locale)
        let spoken = MinutesFormatting.string(
            minutes: Int(SleepTimerPanelModel.adjustment / 60), spoken: true, locale: locale)
        return AdaptiveStack(spacing: ABSSpacing.medium) {
            adjustment(minutes, systemImage: "minus", accessibilityKey: "ButtonSleepTimerSubtract", spoken: spoken) {
                panel.subtract()
            }
            SleepTimerCountdown(panel: panel)
                .frame(maxWidth: .infinity)
            adjustment(minutes, systemImage: "plus", accessibilityKey: "ButtonSleepTimerAdd", spoken: spoken) {
                panel.add()
            }
        }
        .padding(.vertical, ABSSpacing.small)
    }

    private func adjustment(
        _ text: String, systemImage: String, accessibilityKey: String, spoken: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label {
                Text(verbatim: text)
                    .monospacedDigit()
            } icon: {
                Image(systemName: systemImage)
            }
            .labelStyle(.titleAndIcon)
        }
        // Bordered, so the row's three controls are tapped separately.
        .buttonStyle(.bordered)
        .accessibilityLabel(Text(verbatim: L10n.string(accessibilityKey, spoken)))
    }

    /// iOS only: the timer detects shakes only there (D17).
    @ViewBuilder private var shakeHint: some View {
        #if os(iOS)
            if panel.shakeToResetEnabled {
                Text(verbatim: L10n.string("MessageShakeToResetHint"))
            }
        #endif
    }
}

/// The time left, large; the only part of the sheet that redraws every tick.
private struct SleepTimerCountdown: View {
    let panel: SleepTimerPanelModel
    @Environment(\.locale) private var locale

    var body: some View {
        let remaining = panel.remaining ?? 0
        Text(verbatim: SleepTimerSlotPresentation.countdown(remaining, locale: locale))
            .font(.largeTitle.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .accessibilityLabel(
                Text(
                    verbatim: L10n.string(
                        "LabelTimeRemaining", SleepTimerSlotPresentation.spokenRemaining(remaining, locale: locale)))
            )
            .accessibilityAddTraits(.updatesFrequently)
    }
}

#Preview("Idle") {
    let fixture = SleepTimerPreviewFixture(.idle)
    SleepTimerSheet(model: fixture.model, close: {})
        .environment(\.sleepTimer, fixture.timer)
}

#Preview("Running") {
    let fixture = SleepTimerPreviewFixture(.running)
    SleepTimerSheet(model: fixture.model, close: {})
        .environment(\.sleepTimer, fixture.timer)
}

#Preview("Automatic") {
    let fixture = SleepTimerPreviewFixture(.automatic)
    SleepTimerSheet(model: fixture.model, close: {})
        .environment(\.sleepTimer, fixture.timer)
}

#Preview("End of chapter") {
    let fixture = SleepTimerPreviewFixture(.endOfChapter)
    SleepTimerSheet(model: fixture.model, close: {})
        .environment(\.sleepTimer, fixture.timer)
}

#Preview("Grace period") {
    // The one-second timer expires, then offers a restart for two minutes.
    let fixture = SleepTimerPreviewFixture(.gracePeriod)
    SleepTimerSheet(model: fixture.model, close: {})
        .environment(\.sleepTimer, fixture.timer)
}

#Preview("No timer") {
    SleepTimerSheet(model: .preview(), close: {})
}

#Preview("Running, accessibility size") {
    let fixture = SleepTimerPreviewFixture(.automatic)
    SleepTimerSheet(model: fixture.model, close: {})
        .environment(\.sleepTimer, fixture.timer)
        .dynamicTypeSize(.accessibility3)
}

#Preview("Toolbar countdown") {
    @Previewable @State var sheet: PlayerSheet?
    @Previewable @State var fixture = SleepTimerPreviewFixture(.automatic)
    NavigationStack {
        Color.clear
            .toolbar {
                ToolbarItem {
                    SleepTimerSlot(model: fixture.model, sheet: $sheet)
                }
            }
    }
    .sheet(item: $sheet) { _ in
        SleepTimerSheet(model: fixture.model, close: { sheet = nil })
    }
    .environment(\.sleepTimer, fixture.timer)
}
