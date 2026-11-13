import ABSCore
import ABSUI
import AppIntents
import SwiftUI
import WidgetKit

/// Plays or pauses from Control Center, the Lock Screen or the Action button (#89). Its state is
/// the ``WidgetSnapshot``'s play flag, which the app writes, and reloads this control for, when
/// playback starts or stops; ``SetPlayingIntent`` runs in the app (``AudioPlaybackIntent``).
struct PlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetSnapshot.playPauseControlKind, provider: PlayingValueProvider()) {
            isPlaying in
            ControlWidgetToggle(isOn: isPlaying, action: SetPlayingIntent()) {
                Text(LocalizedStringResource("IntentTogglePlaybackTitle", table: "AppIntents"))
            } valueLabel: { isOn in
                // What a tap does: pause while playing, play otherwise.
                Label(L10n.string(isOn ? "ButtonPause" : "ButtonPlay"), systemImage: isOn ? "pause.fill" : "play.fill")
            }
        }
        .displayName(LocalizedStringResource("IntentTogglePlaybackTitle", table: "AppIntents"))
        .description(LocalizedStringResource("IntentTogglePlaybackDescription", table: "AppIntents"))
    }
}

/// Jumps back by the user's interval (``JumpIntent``, run in the app). It shows no state.
struct JumpBackControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetSnapshot.jumpBackControlKind) {
            ControlWidgetButton(action: JumpIntent(direction: .backward)) {
                Label {
                    Text(LocalizedStringResource("IntentJumpBackTitle", table: "AppIntents"))
                } icon: {
                    Image(systemName: "gobackward")
                }
            }
        }
        .displayName(LocalizedStringResource("IntentJumpBackTitle", table: "AppIntents"))
        .description(LocalizedStringResource("IntentJumpDescription", table: "AppIntents"))
    }
}

/// Reads the play/pause control's state from the App Group snapshot.
struct PlayingValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        WidgetSnapshot.isPlaying(at: WidgetSnapshot.defaultFileURL())
    }
}
