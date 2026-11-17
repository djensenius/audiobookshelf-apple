import ABSAppModel
import ABSUI
import SwiftUI

/// The download indicator in each tab root's toolbar (legacy `DownloadProgressIndicator.vue` in
/// `Appbar.vue`): while the signed-in server has downloads in progress, a ring of how far they
/// are around their count, which opens the download queue (``DownloadQueueView``).
struct DownloadQueueToolbar: ToolbarContent {
    @Environment(\.downloads) private var downloads
    @Environment(\.serverID) private var serverID

    var body: some ToolbarContent {
        if let downloads {
            let summary = DownloadQueueSummary(controller: downloads.controller, serverConnectionID: serverID)
            if summary.isVisible {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(value: Route.downloadQueue) {
                        Label {
                            Text(verbatim: L10n.string("HeaderDownloads"))
                        } icon: {
                            DownloadProgressIndicator(fraction: summary.fraction, count: summary.count)
                        }
                        .labelStyle(.iconOnly)
                    }
                    .accessibilityValue(Text(verbatim: L10n.plural("LabelDownloadsInProgress", count: summary.count)))
                    // For UI tests.
                    .accessibilityIdentifier("downloads.queueIndicator")
                }
            }
        }
    }
}
