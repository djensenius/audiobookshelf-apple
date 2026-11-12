import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The Latest section of a podcast library (legacy `pages/bookshelf/latest.vue`): the router's library's episodes,
/// newest first, a page at a time. Builds one ``LatestEpisodesModel`` per store, account and library from
/// `makeServices()`, so a library switch or another account never shows the previous list.
struct LatestView: View {
    @Environment(\.libraryStore) private var store
    @Environment(Router.self) private var router: Router?
    @State private var host: BrowseModelHost<LatestEpisodesModel>?

    var body: some View {
        let libraryID = router?.libraryID
        let key = BrowseModelKey(store: store, libraryID: libraryID)
        Group {
            if let model = host?.model(for: key) {
                LatestEpisodesContent(model: model)
            } else {
                BrowsePlaceholder(libraryID: libraryID, messages: LatestPresentation.messages)
            }
        }
        .navigationTitle(Text(verbatim: L10n.string("HeaderLatestEpisodes")))
        .task(id: key) {
            host = .updated(host, for: key, store: store) { key, services, progress in
                LatestPresentation.makeModel(key: key, services: services, progress: progress)
            }
            if let list = host?.model.list, list.items.isEmpty, !list.reachedEnd {
                await list.loadNextPage()?.value
            }
        }
    }
}

/// The episode list of one model; previews give it a fixture service. Plays and marks episodes through the
/// environment's `playItem` and `itemActions`, as the podcast screen does, with an alert when that fails.
struct LatestEpisodesContent: View {
    let model: LatestEpisodesModel
    @Environment(\.itemActions) private var itemActions
    @Environment(\.playItem) private var playItem
    /// The episode whose Play is starting, so no other Play starts meanwhile.
    @State private var startingID: String?
    /// The episodes whose finished state is being changed.
    @State private var updatingIDs: Set<String> = []
    /// The key of the message for the last failed action, kept while the alert is dismissed.
    @State private var failureKey: String?
    @State private var showsFailure = false
    /// The last user refresh failed and nothing loaded since.
    @State private var refreshFailed = false
    /// Successful user refreshes; rows report appearing again after each (as in ``BrowseItemGrid``).
    @State private var refreshes = 0

    var body: some View {
        let list = model.list
        let messages = LatestPresentation.messages
        let context = PodcastEpisodeActions.context(canPlay: playItem != nil)
        BrowseStateView(state: .resolve(list: list), messages: messages, retry: { retry() }) { failed in
            let placement = BrowsePresentation.failurePlacement(failed: failed, refreshFailed: refreshFailed)
            // One timeline for the list, so "3 days ago" stays current without a timer per row.
            TimelineView(.everyMinute) { timeline in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if placement == .top {
                            BrowseFailureRow(messageKey: messages.failed, retry: { Task { await refresh() } })
                        }
                        ForEach(list.items) { row in
                            LatestEpisodeRow(
                                model: model, row: row, context: context, now: timeline.date,
                                isStarting: startingID == row.id,
                                isOtherStarting: startingID != nil && startingID != row.id,
                                isUpdating: updatingIDs.contains(row.id)
                            ) { kind in
                                perform(kind, on: row)
                            }
                            .padding(.horizontal, ABSSpacing.large)
                            .task(id: refreshes) { list.itemAppeared(id: row.id) }
                            Divider()
                                .padding(.leading, ABSSpacing.large)
                        }
                        BrowsePagingFooter(
                            isLoading: list.isLoading, failed: placement == .footer, messageKey: messages.failed,
                            retry: { retry() })
                    }
                    .padding(.vertical, ABSSpacing.large)
                    .frame(maxWidth: 1_000)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .refreshable { await refresh() }
        .refreshCommand(.root(.latest), isDisabled: list.isLoading) { Task { await refresh() } }
        .onChange(of: list.error == nil) { _, cleared in
            if cleared { refreshFailed = false }
        }
        .alert(
            Text(verbatim: failureKey.map { L10n.string($0) } ?? ""), isPresented: $showsFailure,
            presenting: failureKey
        ) { _ in
            Button(L10n.string("ButtonOk")) {}
        }
    }

    private func refresh() async {
        refreshFailed = await BrowsePresentation.refresh(model.list)
        if !refreshFailed { refreshes += 1 }
    }

    private func retry() {
        BrowsePresentation.retry(model.list)
    }

    /// Plays or marks `row`'s episode, as the podcast screen does; a failure shows the alert.
    private func perform(_ kind: ItemActionKind, on row: LatestEpisode) {
        let isFinished = model.itemProgress(for: row)?.isFinished == true
        let actions = itemActions
        let play = playItem
        let isPlay = kind == .play
        if isPlay {
            guard startingID == nil else { return }
            startingID = row.id
        } else {
            guard updatingIDs.insert(row.id).inserted else { return }
        }
        Task {
            let key = await PodcastEpisodeActions.perform(
                kind, on: row.summary, isFinished: isFinished, actions: actions, play: play)
            if isPlay {
                startingID = nil
            } else {
                updatingIDs.remove(row.id)
            }
            if let key {
                failureKey = key
                showsFailure = true
            }
        }
    }
}

#if DEBUG
    import ABSAPI

    /// Serves ``SampleLibrary``'s episodes, with one in progress and one finished, or fails every request.
    private struct LatestPreviewService: LatestEpisodesService {
        struct Failure: Error {}

        var fails = false

        func recentEpisodes(libraryID: String, page: Int, limit: Int) async throws -> RecentEpisodesPage {
            if fails { throw Failure() }
            let podcast = Podcast(
                id: "pod_1", libraryItemId: SampleLibrary.podcast.id,
                metadata: PodcastMetadata(title: "Classic Tales", explicit: true),
                coverPath: "/metadata/items/li_podcast/cover.jpg")
            let episodes =
                [
                    PodcastEpisode(
                        id: "ep_3", libraryItemId: SampleLibrary.podcast.id, episode: "3", episodeType: .bonus,
                        title: "Episode 3: The Speckled Band, a story with a title long enough to wrap",
                        description:
                            "<p>Holmes and Watson take on a locked-room mystery. A rare snake is involved.</p>",
                        publishedAt: Int(Date.now.addingTimeInterval(-2 * 86_400).timeIntervalSince1970) * 1_000,
                        duration: 2_400)
                ] + SampleLibrary.episodes
            let rows = page == 0 ? episodes.map { RecentEpisode(episode: Self.inItem($0), podcast: podcast) } : []
            return RecentEpisodesPage(episodes: rows, limit: limit, page: page)
        }

        private static func inItem(_ episode: PodcastEpisode) -> PodcastEpisode {
            guard episode.libraryItemId == nil else { return episode }
            return PodcastEpisode(
                id: episode.id, libraryItemId: SampleLibrary.podcast.id, title: episode.title,
                subtitle: "A case for Sherlock Holmes.", duration: episode.duration)
        }
    }

    @MainActor
    private func latestPreviewModel(fails: Bool = false) -> LatestEpisodesModel {
        let progress = ProgressCache()
        progress.apply(
            MediaProgress(
                id: "mp_1", libraryItemId: SampleLibrary.podcast.id, episodeId: "ep_1", duration: 2_100,
                progress: 0.6, currentTime: 1_260))
        progress.apply(
            MediaProgress(
                id: "mp_2", libraryItemId: SampleLibrary.podcast.id, episodeId: "ep_2", progress: 1, isFinished: true))
        return LatestEpisodesModel(
            service: LatestPreviewService(fails: fails), libraryID: SampleLibrary.libraryID, cache: progress)
    }

    #Preview("Latest") {
        @Previewable @State var model = latestPreviewModel()
        NavigationStack {
            LatestEpisodesContent(model: model)
                .navigationTitle(Text(verbatim: L10n.string("HeaderLatestEpisodes")))
        }
        .task { await model.list.loadNextPage()?.value }
        .environment(\.serverID, UUID())
        .absBackground()
    }

    #Preview("Latest, dark, largest text") {
        @Previewable @State var model = latestPreviewModel()
        NavigationStack {
            LatestEpisodesContent(model: model)
                .navigationTitle(Text(verbatim: L10n.string("HeaderLatestEpisodes")))
        }
        .task { await model.list.loadNextPage()?.value }
        .absBackground()
        .environment(\.dynamicTypeSize, .accessibility5)
        .preferredColorScheme(.dark)
    }

    #Preview("Latest, failed") {
        @Previewable @State var model = latestPreviewModel(fails: true)
        NavigationStack {
            LatestEpisodesContent(model: model)
                .navigationTitle(Text(verbatim: L10n.string("HeaderLatestEpisodes")))
        }
        .task { await model.list.loadNextPage()?.value }
        .absBackground()
    }
#endif

#Preview("Signed out") {
    NavigationStack { LatestView() }
        .absBackground()
}
