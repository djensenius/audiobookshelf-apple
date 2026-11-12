import ABSAppModel
import ABSUI
import SwiftUI

/// The full player's bottom toolbar: chapters, bookmarks, the sleep timer and more (the legacy
/// player's top bar and menu). Each slot is a disabled placeholder until #57 adds its sheet.
struct PlayerActionsBar: ToolbarContent {
    let model: PlayerViewModel

    private struct Slot: Identifiable {
        let key: String
        let symbol: String
        var id: String { key }
    }

    private static let slots = [
        Slot(key: "HeaderChapters", symbol: "list.bullet"),
        Slot(key: "LabelYourBookmarks", symbol: "bookmark"),
        Slot(key: "LabelSleepTimer", symbol: "moon.zzz"),
        Slot(key: "LabelMore", symbol: "ellipsis.circle"),
    ]

    private static var placement: ToolbarItemPlacement {
        #if os(iOS)
            .bottomBar
        #else
            .automatic
        #endif
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: Self.placement) {
            ForEach(Self.slots) { slot in
                Button {
                    // #57 presents this slot's sheet.
                } label: {
                    Label {
                        Text(verbatim: L10n.string(slot.key))
                    } icon: {
                        Image(systemName: slot.symbol)
                    }
                }
                .disabled(true)
            }
        }
    }
}
