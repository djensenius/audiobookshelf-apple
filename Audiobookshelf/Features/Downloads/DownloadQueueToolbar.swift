import ABSAppModel
import ABSUI
import SwiftUI

/// The download indicator in each tab root's toolbar (legacy `DownloadProgressIndicator.vue` in
/// `Appbar.vue`): while the signed-in server's download queue isn't empty, a ring of how far it is
/// around its count, which pushes the queue (``DownloadQueueView``) on the tab's stack. It shows
/// the count and ring of the queue's Downloading header. Only the button reads the live progress,
/// so a progress update redraws the ring, not the toolbar.
///
/// It's there only while something downloads, so it outranks the bar's other items (#685): a crowded
/// bar, such as the compact Library root's, moves those into its overflow menu instead.
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
                .visibilityPriority(Self.visibilityPriority)
            }
        }
    }

    /// Above the Library screen's filter and sort (`LibraryToolbar`), the bar's highest otherwise.
    static let visibilityPriority = ToolbarItemVisibilityPriority(higherThan: .high)

    /// The button's accessibility value: how many downloads and how far they are, for example "1 download, 50% done".
    static func accessibilityValue(count: Int, fraction: Double, locale: Locale = .current) -> String {
        L10n.plural(
            "LabelDownloadQueueAccessibility", count: count,
            fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale)), locale: locale)
    }

    /// Pushes the download queue on `tab`'s stack unless it's already on top (a double click).
    @MainActor
    static func open(in router: Router?, on tab: AppTab) {
        guard let router, router[path: tab].last != .downloadQueue else { return }
        router[path: tab].append(.downloadQueue)
    }
}

/// The ring itself is the button's label, not a `Label`'s icon: an iOS 27 bar shows an icon-only
/// `Label` with a custom icon as its title instead (#686). VoiceOver reads the title and the count
/// and progress, as the ring hides its count.
private struct DownloadQueueButton: View {
    let controller: DownloadsController
    let serverID: UUID?
    let count: Int
    let action: () -> Void

    var body: some View {
        let fraction = DownloadsListing.downloadingFraction(
            records: controller.records, progress: controller.progress, serverConnectionID: serverID)
        let title = L10n.string("HeaderDownloading")
        let value = DownloadQueueToolbar.accessibilityValue(count: count, fraction: fraction)
        Button(action: action) {
            DownloadProgressIndicator(fraction: fraction, count: count)
        }
        .accessibilityShowsLargeContentViewer {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: "arrow.down.circle")
            }
        }
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: value))
        // For UI tests.
        .accessibilityIdentifier("downloads.queueIndicator")
    }
}
