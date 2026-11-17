import ABSAppModel
import ABSUI
import SwiftUI

/// The download indicator in each tab root's toolbar (legacy `DownloadProgressIndicator.vue` in
/// `Appbar.vue`): while the signed-in server's download queue isn't empty, a ring of how far it is
/// around its count, which pushes the queue (``DownloadQueueView``) on the tab's stack. It shows
/// the count and ring of the queue's Downloading header. Only the button reads the live progress,
/// so a progress update redraws the ring, not the toolbar.
struct DownloadQueueToolbar: ToolbarContent {
    /// The tab whose root shows the toolbar, and whose stack the queue is pushed on.
    let tab: AppTab
    @Environment(\.downloads) private var downloads
    @Environment(\.serverID) private var serverID
    @Environment(Router.self) private var router: Router?

    var body: some ToolbarContent {
        if let controller = downloads?.controller {
            let count = DownloadsListing.downloadCount(records: controller.records, serverConnectionID: serverID)
            if count > 0 {
                ToolbarItem(placement: .primaryAction) {
                    DownloadQueueButton(controller: controller, serverID: serverID, count: count) {
                        DownloadQueueToolbar.open(in: router, on: tab)
                    }
                }
            }
        }
    }

    /// Pushes the download queue on `tab`'s stack unless it's already on top (a double click).
    @MainActor
    static func open(in router: Router?, on tab: AppTab) {
        guard let router, router[path: tab].last != .downloadQueue else { return }
        router[path: tab].append(.downloadQueue)
    }
}

private struct DownloadQueueButton: View {
    let controller: DownloadsController
    let serverID: UUID?
    let count: Int
    let action: () -> Void

    var body: some View {
        let fraction = DownloadsListing.downloadingFraction(
            records: controller.records, progress: controller.progress, serverConnectionID: serverID)
        Button(action: action) {
            Label {
                Text(verbatim: L10n.string("HeaderDownloading"))
            } icon: {
                DownloadProgressIndicator(fraction: fraction, count: count)
            }
            .labelStyle(.iconOnly)
        }
        .accessibilityShowsLargeContentViewer {
            Label {
                Text(verbatim: L10n.string("HeaderDownloading"))
            } icon: {
                Image(systemName: "arrow.down.circle")
            }
        }
        .accessibilityValue(
            Text(
                verbatim: L10n.plural(
                    "LabelDownloadQueueAccessibility", count: count,
                    fraction.formatted(.percent.precision(.fractionLength(0)))))
        )
        // For UI tests.
        .accessibilityIdentifier("downloads.queueIndicator")
    }
}
