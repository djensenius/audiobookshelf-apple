import ABSAppModel
import ABSUI
import SwiftUI

/// The full player's bottom toolbar: chapters, bookmarks, the sleep timer and more (the legacy
/// player's top bar and menu). Each slot lives in its sheet's file and sets `sheet` to present it;
/// More is a disabled placeholder.
///
/// While the player is split, its details pane shows chapters and bookmarks, so the bar leaves
/// them out (ADR 0004: sheets only when not split).
struct PlayerActionsBar: ToolbarContent {
    let model: PlayerViewModel
    @Binding var sheet: PlayerSheet?
    var showsDetailSlots = true

    private static var placement: ToolbarItemPlacement {
        #if os(iOS)
            .bottomBar
        #else
            .automatic
        #endif
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: Self.placement) {
            if showsDetailSlots {
                ChaptersSlot(model: model, sheet: $sheet)
                BookmarksSlot(model: model, sheet: $sheet)
            }
            SleepTimerSlot(model: model, sheet: $sheet)
            Button {
            } label: {
                Label {
                    Text(verbatim: L10n.string("LabelMore"))
                } icon: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .disabled(true)
        }
    }
}
