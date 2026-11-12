import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// A podcast episode (`Route.episode`, legacy `pages/item/_id/_episode/index.vue`).
///
/// As ``ItemDetailView``, the model belongs to one item, episode and account (ADR 0004): it is
/// built from the environment's `libraryStore` and rebuilt when the item or episode ID, the
/// store or the store's account changes, so nothing loaded for an earlier session shows. Without
/// a store or a connected account (signed out) the screen says the episode is unavailable. The
/// server's address, for Share, is read again each time the screen appears.
struct EpisodeDetailView: View {
    let itemID: String
    let episodeID: String
    @Environment(\.libraryStore) private var store
    @State private var host: EpisodeDetailHost?
    /// The key the store had no client for.
    @State private var unavailableKey: EpisodeDetailHost.Key?

    private var key: EpisodeDetailHost.Key? {
        guard let store, let connectionKey = store.connectionKey else { return nil }
        return EpisodeDetailHost.Key(
            itemID: itemID, episodeID: episodeID, store: ObjectIdentifier(store), connectionKey: connectionKey)
    }

    var body: some View {
        Group {
            if let host, host.key == key {
                EpisodeDetailScreen(model: host.model, serverURL: host.serverURL, playlists: host.services)
            } else if key == nil || unavailableKey == key {
                ErrorStateView(title: L10n.string("MessageEpisodeDetailUnavailable"), systemImage: "waveform")
                    .navigationTitle(Text(verbatim: L10n.string("LabelEpisode")))
            } else {
                LoadingView()
            }
        }
        .task(id: key) {
            guard let key, let store else {
                host = nil
                return
            }
            if host?.key != key {
                guard let services = store.makeServices(), services.connectionKey == key.connectionKey else {
                    host = nil
                    unavailableKey = key
                    return
                }
                unavailableKey = nil
                let detail = ItemDetailModel(itemID: itemID, service: services, cache: store.progress)
                host = EpisodeDetailHost(
                    key: key, services: services,
                    model: EpisodeDetailModel(detail: detail, episodeID: episodeID, cache: store.progress))
            }
            if let services = host?.services, let url = try? await services.serverURL(), host?.key == key {
                host?.serverURL = url
            }
            // Also retries a first load cancelled when the view disappeared.
            await host?.model.detail.loadIfNeeded()
        }
    }
}

/// The model for one episode and account.
private struct EpisodeDetailHost {
    struct Key: Hashable {
        let itemID: String
        let episodeID: String
        let store: ObjectIdentifier
        let connectionKey: LibraryConnectionKey
    }

    let key: Key
    let services: LibraryStoreServices
    let model: EpisodeDetailModel
    /// The server's address, for Share; `nil` until read, or when the client can't tell.
    var serverURL: URL?
}

/// The states of one episode's screen: loading, failed, not found (the podcast or the episode
/// is gone), or the episode, with its title and More menu.
struct EpisodeDetailScreen: View {
    let model: EpisodeDetailModel
    /// The server's address, for the More menu's Share; without it there is no Share.
    var serverURL: URL?
    /// The account's playlist writes, for the More menu's Add to playlist; without them there is no Add to playlist.
    var playlists: (any PlaylistEditingService)?

    var body: some View {
        content
            .navigationTitle(Text(verbatim: model.episode?.title ?? L10n.string("LabelEpisode")))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .episodeDetailMoreMenu(model: model, serverURL: serverURL, playlists: playlists)
    }

    @ViewBuilder private var content: some View {
        let detail = model.detail
        switch EpisodeDetailPresentation.screen(for: model) {
        case .episode:
            if let episode = model.episode {
                EpisodeDetailContent(model: model, episode: episode)
            }
        case .notFound:
            ErrorStateView(title: L10n.string("MessageEpisodeDetailNotFound"), systemImage: "waveform") {
                Task { await detail.load() }
            }
        case .failed:
            ErrorStateView(title: L10n.string("MessageEpisodeDetailLoadFailed")) {
                Task { await detail.load() }
            }
        case .loading:
            LoadingView()
        }
    }
}

// MARK: - Previews

/// ``EpisodeDetailScreen`` over a preview podcast and progress, with a `playItem` that logs its
/// start, or none when `canPlay` is off (signed out).
private struct EpisodeDetailPreview: View {
    @State private var model: EpisodeDetailModel
    private let canPlay: Bool

    init(
        episodeID: String = "pe_2", behavior: PreviewItemDetailService.Behavior = .succeed, canPlay: Bool = true
    ) {
        let item = PodcastDetailPreviewData.podcast
        let cache = ProgressCache()
        for progress in PodcastDetailPreviewData.progress { cache.apply(progress) }
        let detail = ItemDetailModel(
            itemID: item.id, service: PreviewItemDetailService(item: item, behavior: behavior), cache: cache)
        _model = State(initialValue: EpisodeDetailModel(detail: detail, episodeID: episodeID, cache: cache))
        self.canPlay = canPlay
    }

    var body: some View {
        NavigationStack {
            EpisodeDetailScreen(model: model, serverURL: URL(string: "https://abs.example.com"))
                .task { await model.detail.loadIfNeeded() }
        }
        .environment(
            \.playItem,
            canPlay
                ? PlayItemAction { itemID, episodeID, startTime in
                    Log.ui.notice(
                        "Preview play \(itemID, privacy: .public) \(episodeID ?? "", privacy: .public) from \(startTime.map { "\($0)" } ?? "saved position", privacy: .public)"
                    )
                } : nil)
    }
}

#Preview("In progress") {
    EpisodeDetailPreview()
}

#Preview("In progress, dark") {
    EpisodeDetailPreview()
        .preferredColorScheme(.dark)
}

#Preview("Accessibility text size") {
    EpisodeDetailPreview()
        .environment(\.dynamicTypeSize, .accessibility5)
}

#Preview("Finished") {
    EpisodeDetailPreview(episodeID: "pe_3")
}

#Preview("Trailer, not started") {
    EpisodeDetailPreview(episodeID: "pe_1")
}

#Preview("Signed out player") {
    EpisodeDetailPreview(canPlay: false)
}

#Preview("Loading") {
    EpisodeDetailPreview(behavior: .hang)
}

#Preview("Failed") {
    EpisodeDetailPreview(behavior: .fail)
}

#Preview("Not found") {
    EpisodeDetailPreview(behavior: .notFound)
}

#Preview("Episode not in podcast") {
    EpisodeDetailPreview(episodeID: "pe_missing")
}

#Preview("No library store") {
    NavigationStack { EpisodeDetailView(itemID: "li_1", episodeID: "ep_1") }
}
