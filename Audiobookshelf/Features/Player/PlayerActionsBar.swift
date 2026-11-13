import ABSAppModel
import ABSUI
import SwiftUI

/// The full player's bottom toolbar: chapters, bookmarks, the sleep timer, the queue and more (the
/// legacy player's top bar and menu). Each slot lives in its sheet's file and sets `sheet` to present it;
/// More is the ``PlayerOptionsMenu``.
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
            QueueSlot(sheet: $sheet)
            PlayerOptionsMenu(model: model)
        }
    }
}
