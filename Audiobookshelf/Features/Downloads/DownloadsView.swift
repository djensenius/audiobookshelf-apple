import ABSAppModel
import SwiftUI

/// The Downloads tab (legacy `pages/downloads.vue`). A stub until the Downloads feature
/// replaces this file.
struct DownloadsView: View {
    var body: some View {
        FeatureStub(titleKey: AppTab.downloads.titleKey, systemImage: AppTab.downloads.systemImage)
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

/// A downloaded item (legacy `pages/localMedia/item/_id.vue`). A stub until the Downloads
/// feature replaces this file.
struct LocalItemView: View {
    let localItemID: String

    var body: some View {
        FeatureStub(titleKey: "ButtonLocalMedia", systemImage: "internaldrive", details: [localItemID])
    }
}

/// The download queue (legacy `pages/downloading.vue`). A stub until the Downloads feature
/// replaces this file.
struct DownloadQueueView: View {
    var body: some View {
        FeatureStub(titleKey: "MessageDownloading", systemImage: "arrow.down.circle.dotted")
    }
}

#Preview("Downloads") {
    NavigationStack { DownloadsView() }
}

#Preview("Queue") {
    NavigationStack { DownloadQueueView() }
}
