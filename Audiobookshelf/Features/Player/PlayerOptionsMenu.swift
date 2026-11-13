import ABSAppModel
import ABSUI
import SwiftUI

/// The full player's More menu (the legacy player's menu): the total and chapter tracks, scaling
/// the elapsed time by speed, and locking the player (``PlayerDisplayOptions``). Each choice is
/// saved in ``AppSettings`` at once.
struct PlayerOptionsMenu: View {
    let model: PlayerViewModel

    var body: some View {
        let options = model.displayOptions
        Menu {
            Toggle(isOn: binding(options.totalTrack, model.toggleTotalTrack)) {
                Text(verbatim: L10n.string("LabelTotalTrack"))
            }
            Toggle(isOn: binding(options.chapterTrack, model.toggleChapterTrack)) {
                Text(verbatim: L10n.string("LabelChapterTrack"))
            }
            Toggle(isOn: binding(options.scalesElapsedTimeBySpeed, model.toggleScaleElapsedTimeBySpeed)) {
                Text(verbatim: L10n.string("LabelScaleElapsedTimeBySpeed"))
            }
            Button {
                model.toggleLock()
            } label: {
                Label {
                    Text(verbatim: L10n.string(options.isLocked ? "LabelUnlockPlayer" : "LabelLockPlayer"))
                } icon: {
                    Image(systemName: options.isLocked ? "lock.open" : "lock")
                }
            }
        } label: {
            Label {
                Text(verbatim: L10n.string("LabelMore"))
            } icon: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    /// A toggle binding that shows `value` and calls `toggle` when changed, so the model applies
    /// the options' rules (one of the tracks stays on).
    private func binding(_ value: Bool, _ toggle: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { value }, set: { if $0 != value { toggle() } })
    }
}

#Preview {
    NavigationStack {
        Text(verbatim: "Player")
            .toolbar {
                ToolbarItem {
                    PlayerOptionsMenu(model: .preview(at: 9_500))
                }
            }
    }
}
