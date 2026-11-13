import ABSAppModel
import ABSUI
import SwiftUI

/// The Downloads tab (legacy `pages/downloads.vue`): the downloads under way, then the
/// signed-in server's downloaded books and podcasts with their sizes and the free space.
struct DownloadsView: View {
    @Environment(\.downloads) private var downloads

    var body: some View {
        Group {
            if let downloads {
                DownloadsList(services: downloads, mode: .all)
            } else {
                DownloadsUnavailableView()
            }
        }
        .navigationTitle(Text(verbatim: L10n.string("HeaderDownloads")))
    }
}

/// A local media folder (legacy `pages/localMedia/folders/_id.vue`). A stub until the Downloads
/// feature replaces this file.
struct LocalFolderView: View {
    let folderID: String

    var body: some View {
        FeatureStub(titleKey: "LabelFolder", systemImage: "folder", details: [folderID])
    }
}

/// A downloaded item (legacy `pages/localMedia/item/_id.vue`), by its local ID; see
/// ``LocalItemDetailView``.
struct LocalItemView: View {
    let localItemID: String
    @Environment(\.downloads) private var downloads

    var body: some View {
        if let downloads, let id = UUID(uuidString: localItemID) {
            LocalItemDetailView(itemID: id, services: downloads)
                .id(id)
        } else if downloads == nil {
            DownloadsUnavailableView()
        } else {
            ContentUnavailableView {
                Label {
                    Text(verbatim: L10n.string("MessageLocalItemNotFound"))
                } icon: {
                    Image(systemName: "internaldrive")
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

/// The downloads under way (legacy `pages/downloading.vue`), with cancel and retry.
struct DownloadQueueView: View {
    @Environment(\.downloads) private var downloads

    var body: some View {
        Group {
            if let downloads {
                DownloadsList(services: downloads, mode: .queue)
            } else {
                DownloadsUnavailableView()
            }
        }
        .navigationTitle(Text(verbatim: L10n.string("HeaderDownloading")))
    }
}

/// Shown where the app has no download stack (the on-device store couldn't be opened).
private struct DownloadsUnavailableView: View {
    var body: some View {
        ContentUnavailableView {
            Label {
                Text(verbatim: L10n.string("MessageDownloadsUnavailable"))
            } icon: {
                Image(systemName: "arrow.down.circle")
                    .accessibilityHidden(true)
            }
        }
    }
}

#Preview("Downloads") {
    NavigationStack { DownloadsView() }
}

#Preview("Queue") {
    NavigationStack { DownloadQueueView() }
}
