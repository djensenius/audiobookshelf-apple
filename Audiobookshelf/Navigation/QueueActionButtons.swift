import ABSAppModel
import ABSCore
import ABSPlayback
import ABSUI
import SwiftUI

extension EnvironmentValues {
    /// The running account session's play queue, for Play Next and Add to Queue; `nil` between
    /// sessions, so they aren't offered. Set by ``PlaybackEnvironment``.
    @Entry var queueActions: PlaybackQueueControl?
}

/// Play Next and Add to Queue for a menu (the book and episode More menus, an episode row's
/// context menu): queues the book `item`, or its `episode`, through the environment's
/// ``EnvironmentValues/queueActions`` and announces it for VoiceOver. Shows nothing without an
/// item, for what can't be played (``QueueItem/init(item:episode:)``), without a queue, or for
/// the media the player has loaded, which the queue can't play next (``PlaybackQueueControl/isCurrent(_:)``).
struct QueueActionButtons: View {
    let item: ABSCore.LibraryItem?
    var episode: ABSCore.PodcastEpisode?
    @Environment(\.queueActions) private var queue

    var body: some View {
        if let queue, let item = item.flatMap({ QueueItem(item: $0, episode: episode) }), !queue.isCurrent(item) {
            ForEach(QueuePlacement.allCases, id: \.self) { placement in
                Button {
                    guard queue.add(item, at: placement) else { return }
                    AccessibilityNotification.Announcement(
                        L10n.string(QueueActionPresentation.announcementKey(for: placement))
                    ).post()
                } label: {
                    Label(
                        L10n.string(QueueActionPresentation.titleKey(for: placement)),
                        systemImage: QueueActionPresentation.systemImage(for: placement))
                }
            }
        }
    }
}

/// The titles, icons and announcements of Play Next and Add to Queue.
enum QueueActionPresentation {
    static func titleKey(for placement: QueuePlacement) -> String {
        switch placement {
        case .next: "ButtonPlayNext"
        case .end: "ButtonAddToQueue"
        }
    }

    static func systemImage(for placement: QueuePlacement) -> String {
        switch placement {
        case .next: "text.line.first.and.arrowtriangle.forward"
        case .end: "text.line.last.and.arrowtriangle.forward"
        }
    }

    static func announcementKey(for placement: QueuePlacement) -> String {
        switch placement {
        case .next: "MessageQueuedToPlayNext"
        case .end: "MessageQueuedAtEnd"
        }
    }
}
