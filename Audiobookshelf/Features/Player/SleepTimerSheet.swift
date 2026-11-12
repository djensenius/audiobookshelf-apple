import ABSAppModel
import ABSUI
import SwiftUI

/// The toolbar's sleep timer button; disabled until the sleep timer sheet (P2-58b) replaces this
/// file.
struct SleepTimerSlot: View {
    let model: PlayerViewModel
    @Binding var sheet: PlayerSheet?

    var body: some View {
        Button {
            sheet = .sleepTimer
        } label: {
            Label {
                Text(verbatim: L10n.string("LabelSleepTimer"))
            } icon: {
                Image(systemName: "moon.zzz")
            }
        }
        .disabled(true)
    }
}

/// The sleep timer sheet; a placeholder until P2-58b.
struct SleepTimerSheet: View {
    let model: PlayerViewModel
    let close: () -> Void

    var body: some View {
        PlayerSheetPlaceholder(titleKey: "HeaderSleepTimer", systemImage: "moon.zzz", close: close)
    }
}

#Preview("Sheet") {
    SleepTimerSheet(model: .preview(), close: {})
}

#Preview("Sheet, accessibility size") {
    SleepTimerSheet(model: .preview(), close: {})
        .dynamicTypeSize(.accessibility3)
}
