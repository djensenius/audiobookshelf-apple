import ABSAppModel
import ABSUI
import SwiftUI

/// A sheet the full player presents. ``NowPlayingView`` holds one per window, so opening a sheet in
/// one window doesn't open it in another (ADR 0004).
enum PlayerSheet: String, Identifiable {
    case chapters, bookmarks, speed, sleepTimer, queue

    var id: String { rawValue }
}

/// The view for each ``PlayerSheet``. Each sheet and its toolbar slot live in their own file
/// (`ChaptersSheet.swift`, `BookmarksSheet.swift`, `PlaybackSpeedSheet.swift`,
/// `SleepTimerSheet.swift`, `QueueSheet.swift`) and apply ``SwiftUICore/View/playerSheetStyle(title:detents:onDone:)``
/// themselves, so changing one sheet doesn't touch this host or the player.
struct PlayerSheetContent: View {
    let sheet: PlayerSheet
    let model: PlayerViewModel
    /// Dismisses the sheet.
    let close: () -> Void

    var body: some View {
        switch sheet {
        case .chapters: ChaptersSheet(model: model, close: close)
        case .bookmarks: BookmarksSheet(model: model, close: close)
        case .speed: PlaybackSpeedSheet(model: model, close: close)
        case .sleepTimer: SleepTimerSheet(model: model, close: close)
        case .queue: QueueSheet(close: close)
        }
    }
}

extension View {
    /// The player sheets' frame: a navigation bar with `title` and a Done button. On iOS the sheet
    /// has `detents` and the trailing placement (vertical on the iPhone Duo's outer display,
    /// ADR 0004); on macOS, where sheets don't resize to their content, a fixed size, ignoring
    /// `detents`.
    func playerSheetStyle(
        title: String, detents: Set<PresentationDetent> = [.medium, .large], onDone: @escaping () -> Void
    ) -> some View {
        modifier(PlayerSheetStyle(title: title, detents: detents, onDone: onDone))
    }
}

private struct PlayerSheetStyle: ViewModifier {
    let title: String
    let detents: Set<PresentationDetent>
    let onDone: () -> Void

    func body(content: Content) -> some View {
        NavigationStack {
            content
                .navigationTitle(Text(verbatim: title))
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: onDone) {
                            Text(verbatim: L10n.string("ButtonDone"))
                        }
                    }
                }
        }
        #if os(iOS)
            .presentationDetents(detents)
            .presentationDragIndicator(.visible)
            .presentationPlacement(.trailing)
        #else
            .frame(minWidth: 360, idealWidth: 420, minHeight: 420, idealHeight: 520)
        #endif
    }
}

/// The content of a sheet a later slice fills in: its title and symbol, centred.
struct PlayerSheetPlaceholder: View {
    let titleKey: String
    let systemImage: String
    let close: () -> Void

    var body: some View {
        let title = L10n.string(titleKey)
        ContentUnavailableView {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: systemImage)
            }
        }
        .playerSheetStyle(title: title, onDone: close)
    }
}
