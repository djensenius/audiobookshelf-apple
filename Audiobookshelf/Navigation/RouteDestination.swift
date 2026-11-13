import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The screen for a ``Route``, for each tab stack's single `.navigationDestination(for:)`
/// (ADR 0004). Every route opens a screen in the feature folder that owns it; a feature that
/// isn't built yet has a stub there, which its feature PR replaces without touching this file.
///
/// The rule that keeps it that way: each screen is constructed here only from the route's own
/// values (IDs and names). A screen gets its models and services from `@Environment` inside its
/// own file, so a feature PR never needs to change this switch or a screen's initializer.
struct RouteDestination: View {
    let route: Route
    @Environment(AppSettings.self) private var settings: AppSettings?

    var body: some View {
        switch route {
        case .item(let id):
            ItemDetailView(itemID: id)
                .publishesHandoff(itemID: id)
        case .episode(let itemID, let episodeID):
            EpisodeDetailView(itemID: itemID, episodeID: episodeID)
                .publishesHandoff(itemID: itemID, episodeID: episodeID)
        case .series(let id):
            SeriesDetailView(seriesID: id)
        case .author(let id):
            AuthorDetailView(authorID: id)
        case .narrator(let name):
            // Legacy opens the library filtered by the narrator.
            LibraryFilterView(kind: .narrators, value: name)
        case .libraryFilter(let kind, let value):
            LibraryFilterView(kind: kind, value: value)
        case .collection(let id):
            CollectionDetailView(collectionID: id)
        case .playlist(let id):
            PlaylistDetailView(playlistID: id)
        case .history(let itemID, let episodeID):
            PlaybackHistoryDestination(itemID: itemID, episodeID: episodeID)
        case .localFolder(let id):
            LocalFolderView(folderID: id)
        case .localItem(let id):
            LocalItemView(localItemID: id)
        case .downloadQueue:
            DownloadQueueView()
        case .stats:
            StatsView()
        case .logs:
            LogsView()
        case .servers:
            ServersView()
        case .settings:
            if let settings {
                SettingsView(settings: settings)
            }
        }
    }
}

/// A screen whose feature isn't built yet: its localized title and the IDs it was opened with.
/// Each feature's stub uses it until the feature PR replaces the stub. Delete it together with
/// the last stub.
struct FeatureStub: View {
    let titleKey: String
    let systemImage: String
    /// The route's identifying values (IDs or names), shown verbatim.
    var details: [String] = []

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(verbatim: L10n.string(titleKey))
            } icon: {
                Image(systemName: systemImage)
            }
        } description: {
            if !details.isEmpty {
                Text(verbatim: details.joined(separator: "\n"))
            }
        }
        .navigationTitle(Text(verbatim: L10n.string(titleKey)))
    }
}

#Preview("Item") {
    NavigationStack {
        RouteDestination(route: .item(id: "li_1"))
    }
}

#Preview("Narrator filter") {
    NavigationStack {
        RouteDestination(route: .libraryFilter(kind: .narrators, value: "Stephen Fry"))
    }
}
