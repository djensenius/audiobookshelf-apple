import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// A podcast item (legacy `pages/item/_id/index.vue` with a podcast, and its
/// `EpisodesTable.vue`): the header, then the episodes with their filter, sort and search.
/// ``ItemDetailView`` shows it once the item has loaded as a podcast, passing its loaded model
/// so the item isn't fetched twice.
///
/// Progress comes from the environment's library store, the cache the item's model reads (an
/// empty one without a store, as in previews); the filter and sort are saved in the
/// environment's `AppSettings`.
struct PodcastDetailView: View {
    let model: ItemDetailModel
    @Environment(\.libraryStore) private var store
    @Environment(AppSettings.self) private var settings: AppSettings?
    @State private var fallbackProgress = ProgressCache()

    var body: some View {
        let progress = store?.progress ?? fallbackProgress
        PodcastDetailScreen(detail: model, progress: progress, settings: settings)
            // A new item model or cache gets a new screen model.
            .id([ObjectIdentifier(model), ObjectIdentifier(progress)])
    }
}

/// The podcast screen over one ``PodcastDetailModel``. Plays and marks episodes through the
/// environment's `playItem` and `itemActions`, as Home does, and shows an alert when that fails.
struct PodcastDetailScreen: View {
    @State private var model: PodcastDetailModel
    /// The episode whose Play is starting, so no other Play starts meanwhile.
    @State private var startingEpisodeID: String?
    /// The episodes whose finished state is being changed.
    @State private var updatingEpisodeIDs: Set<String> = []
    /// The key of the message for the last failed action, kept while the alert is dismissed.
    @State private var failureKey: String?
    @State private var showsFailure = false
    @State private var goneState = ItemDetailGoneState()
    @Environment(\.itemActions) private var itemActions
    @Environment(\.playItem) private var playItem

    init(detail: ItemDetailModel, progress: ProgressCache, settings: AppSettings?) {
        _model = State(initialValue: PodcastDetailModel(detail: detail, cache: progress, settings: settings))
    }

    var body: some View {
        // `episodes` is rebuilt on every read: read it once.
        let episodes = model.episodes
        let snapshot = ItemDetailGoneState.Snapshot(model: model.detail)
        let isGone = goneState.isGone(snapshot)
        let refreshFailure = ItemDetailRefreshFailure(model: model.detail, isGone: isGone)
        // A podcast gone from the server can't be played, as on the book screen.
        let context = PodcastEpisodeActions.context(canPlay: playItem != nil && !isGone)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let refreshFailure {
                    ItemDetailRefreshFailedBanner(messageKey: refreshFailure.messageKey) {
                        Task { await model.detail.load() }
                    }
                    .padding(.bottom, ABSSpacing.large)
                }
                PodcastDetailHeader(
                    model: model, canPlay: context.canPlay && startingEpisodeID == nil,
                    isStarting: startingEpisodeID != nil && startingEpisodeID == model.nextEpisode?.id
                ) {
                    if let next = model.nextEpisode { perform(.play, on: next) }
                }
                PodcastEpisodeListControls(model: model, count: episodes.count)
                    .padding(.top, ABSSpacing.xLarge)
                    .padding(.bottom, ABSSpacing.small)
                if episodes.isEmpty {
                    emptyState
                } else {
                    ForEach(episodes) { episode in
                        PodcastEpisodeRow(
                            model: model, episode: episode, context: context, isGone: isGone,
                            isStarting: startingEpisodeID == episode.id,
                            isOtherStarting: startingEpisodeID != nil && startingEpisodeID != episode.id,
                            isUpdating: updatingEpisodeIDs.contains(episode.id)
                        ) { kind in
                            perform(kind, on: episode)
                        }
                        Divider()
                    }
                }
            }
            .padding(ABSSpacing.large)
            .frame(maxWidth: 1_000)
            .frame(maxWidth: .infinity)
        }
        .searchable(text: $model.searchText, prompt: Text(verbatim: L10n.string("ButtonSearch")))
        .refreshable { await model.detail.load() }
        .absBackground()
        .onChange(of: snapshot, initial: true) { _, snapshot in goneState.update(snapshot) }
        .navigationTitle(Text(verbatim: model.title))
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.detail.load() }
                    } label: {
                        Label {
                            Text(verbatim: L10n.string("ButtonRefresh"))
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.detail.isLoading)
                }
            }
        #endif
        .alert(
            Text(verbatim: failureKey.map { L10n.string($0) } ?? ""), isPresented: $showsFailure,
            presenting: failureKey
        ) { _ in
            Button(L10n.string("ButtonOk")) {}
        }
    }

    /// No episodes at all, or none the filter and search let through, with Clear Filter.
    private var emptyState: some View {
        let hasEpisodes = !model.allEpisodes.isEmpty
        return ContentUnavailableView {
            Label {
                Text(
                    verbatim: L10n.string(
                        hasEpisodes ? "MessagePodcastDetailNoMatchingEpisodes" : "MessagePodcastDetailNoEpisodes"))
            } icon: {
                Image(systemName: hasEpisodes ? "line.3.horizontal.decrease.circle" : "mic")
                    .accessibilityHidden(true)
            }
        } actions: {
            if hasEpisodes, model.canClearFilter {
                Button {
                    model.clearFilter()
                } label: {
                    Text(verbatim: L10n.string("ButtonClearFilter"))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, ABSSpacing.xLarge)
    }

    /// Plays or marks `episode`, as Home performs its card actions; a failure shows the alert.
    private func perform(_ kind: ItemActionKind, on episode: PodcastEpisode) {
        guard let summary = model.summary(for: episode) else { return }
        let isFinished = model.itemProgress(for: episode)?.isFinished == true
        let actions = itemActions
        let play = playItem
        let isPlay = kind == .play
        if isPlay {
            guard startingEpisodeID == nil else { return }
            startingEpisodeID = episode.id
        } else {
            guard updatingEpisodeIDs.insert(episode.id).inserted else { return }
        }
        Task {
            let key = await PodcastEpisodeActions.perform(
                kind, on: summary, isFinished: isFinished, actions: actions, play: play)
            if isPlay {
                startingEpisodeID = nil
            } else {
                updatingEpisodeIDs.remove(episode.id)
            }
            if let key {
                failureKey = key
                showsFailure = true
            }
        }
    }
}

/// "Episodes (12)" with the filter and sort menus (legacy `EpisodesTable.vue` header). Stacks
/// the menus under the heading at accessibility text sizes.
private struct PodcastEpisodeListControls: View {
    @Bindable var model: PodcastDetailModel
    let count: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    var body: some View {
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ABSSpacing.small))
            : AnyLayout(HStackLayout(spacing: ABSSpacing.small))
        layout {
            Text(
                verbatim: L10n.string(
                    "HeaderPodcastDetailEpisodes", count.formatted(.number.locale(locale)), locale: locale)
            )
            .font(.title3.bold())
            .accessibilityAddTraits(.isHeader)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            HStack(spacing: ABSSpacing.small) {
                filterMenu
                sortMenu
            }
        }
        .buttonStyle(.bordered)
    }

    private var filterMenu: some View {
        let title = L10n.string(PodcastDetailPresentation.titleKey(for: model.filter))
        let menuTitle = L10n.string("LabelPodcastDetailEpisodeFilter")
        return Menu {
            Picker(selection: $model.filter) {
                ForEach(EpisodeListFilter.allCases, id: \.self) { filter in
                    Text(verbatim: L10n.string(PodcastDetailPresentation.titleKey(for: filter))).tag(filter)
                }
            } label: {
                Text(verbatim: menuTitle)
            }
            .pickerStyle(.inline)
        } label: {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(
                    systemName: model.filter == .all
                        ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
        }
        .fixedSize()
        .accessibilityLabel(Text(verbatim: menuTitle))
        .accessibilityValue(Text(verbatim: title))
    }

    private var sortMenu: some View {
        let title = L10n.string(PodcastDetailPresentation.titleKey(for: model.sort))
        let direction = L10n.string(PodcastDetailPresentation.directionKey(isDescending: model.isDescending))
        let menuTitle = L10n.string("LabelPodcastDetailSortEpisodes")
        return Menu {
            Picker(selection: $model.sort) {
                ForEach(EpisodeSortKey.allCases, id: \.self) { sort in
                    Text(verbatim: L10n.string(PodcastDetailPresentation.titleKey(for: sort))).tag(sort)
                }
            } label: {
                Text(verbatim: menuTitle)
            }
            .pickerStyle(.inline)
            Picker(selection: $model.isDescending) {
                ForEach([false, true], id: \.self) { isDescending in
                    Text(verbatim: L10n.string(PodcastDetailPresentation.directionKey(isDescending: isDescending)))
                        .tag(isDescending)
                }
            } label: {
                Text(verbatim: direction)
            }
            .pickerStyle(.inline)
        } label: {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: model.isDescending ? "arrow.down" : "arrow.up")
            }
        }
        .fixedSize()
        .accessibilityLabel(Text(verbatim: menuTitle))
        .accessibilityValue(Text(verbatim: [title, direction].joined(separator: ", ")))
    }
}

// MARK: - Previews

/// A podcast with varied episodes, and progress on some, for the previews.
enum PodcastDetailPreviewData {
    static let podcast: ABSCore.LibraryItem = {
        let day = 86_400_000
        let episodes = [
            PodcastEpisode(
                id: "pe_1", index: 1, season: "1", episode: "1", episodeType: .trailer, title: "Coming Soon",
                subtitle: "A first look at the season.", publishedAt: 1_700_000_000_000, duration: 120),
            PodcastEpisode(
                id: "pe_2", index: 2, season: "1", episode: "2", title: "The Red-Headed League",
                description:
                    "<p>A pawnbroker is paid to copy the <b>encyclopaedia</b>, until the league dissolves.</p>",
                publishedAt: 1_700_000_000_000 + 7 * day, duration: 2_100),
            PodcastEpisode(
                id: "pe_3", index: 3, season: "1", episode: "3", title: "A Scandal in Bohemia",
                publishedAt: 1_700_000_000_000 + 14 * day, duration: 1_800),
            PodcastEpisode(
                id: "pe_4", index: 4, season: "1", episode: "4", episodeType: .bonus,
                title: "Behind the Scenes: Recording Victorian London With a Very Long Episode Title",
                publishedAt: 1_700_000_000_000 + 21 * day, duration: 900),
        ]
        let metadata = PodcastMetadata(
            title: "Classic Tales", author: "Public Domain Players",
            description: "<p>Stories from the <i>public domain</i>, read aloud each week.</p>",
            genres: ["Fiction", "Drama"], explicit: true, type: "episodic")
        return ABSCore.LibraryItem(
            id: "li_podcast_preview", libraryId: SampleLibrary.libraryID, updatedAt: 20, mediaType: .podcast,
            media: .podcast(
                Podcast(
                    id: "pod_preview", libraryItemId: "li_podcast_preview", metadata: metadata,
                    coverPath: "/metadata/items/li_podcast_preview/cover.jpg", tags: ["Weekly"],
                    episodes: episodes)))
    }()

    static let progress = [
        MediaProgress(
            id: "mp_pe_2", libraryItemId: "li_podcast_preview", episodeId: "pe_2", duration: 2_100, progress: 0.4,
            currentTime: 840, lastUpdate: 1),
        MediaProgress(
            id: "mp_pe_3", libraryItemId: "li_podcast_preview", episodeId: "pe_3", duration: 1_800, progress: 1,
            currentTime: 1_800, isFinished: true, lastUpdate: 1),
    ]
}

/// ``PodcastDetailScreen`` over a preview item and progress, with a `playItem` that does nothing.
private struct PodcastDetailPreview: View {
    @State private var detail: ItemDetailModel
    @State private var progress: ProgressCache
    @State private var settings: AppSettings?

    init(item: ABSCore.LibraryItem = PodcastDetailPreviewData.podcast, filter: EpisodeListFilter = .all) {
        let cache = ProgressCache()
        for progress in PodcastDetailPreviewData.progress { cache.apply(progress) }
        _progress = State(initialValue: cache)
        _detail = State(
            initialValue: ItemDetailModel(
                itemID: item.id, service: PreviewItemDetailService(item: item, behavior: .succeed), cache: cache))
        let settings = UserDefaults(suiteName: "PodcastDetailPreview.\(filter.rawValue)").map(
            AppSettings.init(defaults:))
        settings?.podcastEpisodeListPreferences = EpisodeListPreferences(filter: filter).json
        _settings = State(initialValue: settings)
    }

    var body: some View {
        NavigationStack {
            Group {
                if detail.hasLoaded {
                    PodcastDetailScreen(detail: detail, progress: progress, settings: settings)
                } else {
                    LoadingView()
                }
            }
            .task { await detail.loadIfNeeded() }
        }
        .environment(\.playItem, PlayItemAction { _, _, _ in })
    }
}

#Preview("Episodes") {
    PodcastDetailPreview()
}

#Preview("Incomplete only") {
    PodcastDetailPreview(filter: .incomplete)
}

#Preview("In progress") {
    PodcastDetailPreview(filter: .inProgress)
}

#Preview("Accessibility text, iPhone SE width", traits: .fixedLayout(width: 320, height: 1_400)) {
    PodcastDetailPreview()
        .environment(\.dynamicTypeSize, .accessibility2)
}

#Preview("No episodes") {
    ItemDetailPreview(item: SampleLibrary.podcast)
}
