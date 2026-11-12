import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The Add podcast section of a podcast library (legacy `pages/bookshelf/add-podcast.vue`): search the podcast
/// directory or paste an RSS feed URL, then fill in ``NewPodcastForm``. Only admins see the form, as the server
/// refuses everyone else.
///
/// Builds one ``AddPodcastModel`` per account and library, so a switch never shows the previous results. Present it
/// as a section, a route or a sheet; `onCreated` gets the new item's ID, and by default pushes it onto the selected
/// tab's stack.
struct AddPodcastView: View {
    var onCreated: ((String) -> Void)?
    @Environment(AccountManager.self) private var accounts: AccountManager?
    @Environment(\.libraryStore) private var store
    @Environment(Router.self) private var router: Router?
    @State private var model: AddPodcastModel?
    @State private var modelKey: ModelKey?

    /// What a model belongs to; another one rebuilds it. A library refresh that keeps its folders and region keeps
    /// the results.
    private struct ModelKey: Hashable {
        let connectionID: UUID
        let userID: String
        let libraryID: String
        let folders: [LibraryFolder]
        let region: String?
    }

    init(onCreated: ((String) -> Void)? = nil) {
        self.onCreated = onCreated
    }

    var body: some View {
        let user = accounts?.authorization?.user
        let key = currentKey(user: user)
        Group {
            if let user, !user.canAddPodcasts {
                ErrorStateView(
                    title: L10n.string("MessageAddPodcastNotAllowed"), systemImage: "lock")
            } else if let model, modelKey == key {
                AddPodcastContent(model: model) { open($0) }
            } else {
                LoadingView()
            }
        }
        .navigationTitle(Text(verbatim: L10n.string("HeaderAddPodcast")))
        .task(id: key) {
            guard key != modelKey else { return }
            if let key, let client = accounts?.client, let library = findLibrary(id: key.libraryID) {
                model = AddPodcastModel(service: client, library: library)
            } else {
                model = nil
            }
            modelKey = key
        }
    }

    /// The signed-in admin's account and the router's library; `nil` until both are known and agree.
    private func currentKey(user: User?) -> ModelKey? {
        guard let user, user.canAddPodcasts, let connectionID = accounts?.activeConnection?.id,
            store?.connectionKey?.connectionID == connectionID, let libraryID = router?.libraryID,
            let library = findLibrary(id: libraryID)
        else { return nil }
        return ModelKey(
            connectionID: connectionID, userID: user.id, libraryID: libraryID, folders: library.folders ?? [],
            region: library.settings?.podcastSearchRegion)
    }

    private func findLibrary(id: String) -> Library? {
        store?.libraries.first { $0.id == id }
    }

    private func open(_ itemID: String) {
        if let onCreated {
            onCreated(itemID)
        } else if let router {
            router[path: router.selectedTab].append(.item(id: itemID))
        }
    }
}

/// The search field, results and new-podcast sheet of one model; previews give it a fixture service.
struct AddPodcastContent: View {
    @Bindable var model: AddPodcastModel
    let onCreated: (String) -> Void
    @Environment(\.serverID) private var serverID

    var body: some View {
        List {
            ForEach(Array(model.results.enumerated()), id: \.offset) { _, result in
                Button {
                    model.select(result)
                } label: {
                    AddPodcastResultRow(result: result, serverID: serverID)
                }
                .buttonStyle(.plain)
                .disabled(model.isLookingUpFeed)
            }
        }
        .overlay { placeholder }
        .searchable(text: $model.query, prompt: Text(verbatim: L10n.string("MessagePodcastSearchField")))
        .onSubmit(of: .search) { model.submit() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isLookingUpFeed {
                    ProgressView()
                        .accessibilityLabel(Text(verbatim: L10n.string("MessageLoading")))
                } else {
                    // The "paste RSS URL" path: looks the pasted feed up at once.
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        model.query = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.submit()
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        .alert(
            Text(verbatim: model.lookupError.map(Self.message) ?? ""),
            isPresented: Binding(
                get: { model.lookupError != nil }, set: { if !$0 { model.clearLookupError() } })
        ) {
            Button(L10n.string("ButtonOk")) {}
        }
        .sheet(item: $model.draft) { draft in
            NavigationStack {
                NewPodcastForm(draft: draft) { itemID in
                    model.draft = nil
                    onCreated(itemID)
                }
            }
        }
    }

    @ViewBuilder private var placeholder: some View {
        if !model.results.isEmpty {
            EmptyView()
        } else if model.isSearching || model.isLookingUpFeed {
            LoadingView()
        } else if model.searchError != nil {
            ErrorStateView(title: L10n.string("MessagePodcastSearchFailed"), retry: { model.submit() })
        } else if model.searchedTerm != nil {
            AddPodcastPrompt(messageKey: "MessageNoPodcastsFound", systemImage: "magnifyingglass")
        } else {
            AddPodcastPrompt(messageKey: "MessagePodcastSearchField", systemImage: "dot.radiowaves.left.and.right")
        }
    }

    static func message(for error: AddPodcastLookupError) -> String {
        switch error {
        case .noFeed: L10n.string("MessagePodcastNoFeed")
        case .feedFailed: L10n.string("MessagePodcastFeedFailed")
        }
    }
}

private struct AddPodcastPrompt: View {
    let messageKey: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(verbatim: L10n.string(messageKey))
            } icon: {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// One directory result: artwork, title, author, genres and episode count.
private struct AddPodcastResultRow: View {
    let result: PodcastDirectoryResult
    let serverID: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: ABSSpacing.medium) {
            CoverView(
                key: AddPodcastPresentation.coverKey(
                    url: result.cover, id: result.itunesID ?? result.feedURL, serverID: serverID),
                title: result.title, author: result.artistName, shape: .square, accessibility: .hidden
            )
            .frame(width: 64)
            VStack(alignment: .leading, spacing: ABSSpacing.xSmall) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: result.title)
                        .font(.headline)
                    if result.explicit { ExplicitBadge() }
                }
                if let author = result.artistName, !author.isEmpty {
                    Text(verbatim: author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !result.genres.isEmpty {
                    Text(verbatim: result.genres.formatted(.list(type: .and)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let count = result.trackCount {
                    Text(verbatim: L10n.plural("LabelPodcastEpisodeCount", count: count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Covers of podcasts that aren't on the server yet.
enum AddPodcastPresentation {
    /// The external artwork at `url`, cached under `id`; `nil` without a URL or while signed out.
    static func coverKey(url: String?, id: String?, serverID: UUID?) -> ImageKey? {
        guard let url, let externalURL = URL(string: url), let serverID else { return nil }
        return CoverRef(entityID: "add-podcast-\(id ?? url)", externalURL: externalURL).key(serverID: serverID)
    }
}

#if DEBUG
    /// Answers searches with two shows (none for "nothing"), and every feed with one; creates fail for titles
    /// containing "fail".
    struct AddPodcastPreviewService: AddPodcastService {
        struct Failure: Error {}

        func searchPodcastDirectory(term: String, country: String?) async throws -> [PodcastDirectoryResult] {
            if term == "nothing" { return [] }
            if term == "fail" { throw Failure() }
            return [
                PodcastDirectoryResult(
                    itunesID: "1", title: "Classic Tales", artistName: "B. J. Harrison",
                    description: "The finest classic stories, read aloud.", genres: ["Arts", "Books"],
                    trackCount: 812, feedURL: "https://feeds.example.com/classic-tales.xml", explicit: false),
                PodcastDirectoryResult(
                    itunesID: "2", title: "Night Shift Mysteries: A show with a title long enough to wrap",
                    artistName: "Night Shift", genres: ["Fiction"], trackCount: 1, explicit: true),
            ]
        }

        func podcastFeed(rssFeed: String) async throws -> PodcastFeed {
            PodcastFeed(
                metadata: PodcastFeedMetadata(
                    title: "Classic Tales", author: "B. J. Harrison", descriptionPlain: "Stories, read aloud.",
                    categories: ["Arts"], feedURL: rssFeed),
                episodes: [PodcastFeedEpisode(title: "The Speckled Band")], numEpisodes: 812)
        }

        func createPodcast(_ request: NewPodcastRequest) async throws -> ABSCore.LibraryItem {
            if request.media.metadata.title.localizedCaseInsensitiveContains("fail") {
                throw APIError.http(status: 400, message: "Podcast already exists")
            }
            return ABSCore.LibraryItem(id: "li_new", libraryId: request.libraryID, mediaType: .podcast)
        }
    }

    @MainActor
    func addPodcastPreviewModel(query: String? = nil) -> AddPodcastModel {
        let library = Library(
            id: SampleLibrary.libraryID, name: "Podcasts",
            folders: [
                LibraryFolder(id: "fol_1", fullPath: "/podcasts"), LibraryFolder(id: "fol_2", fullPath: "/mnt/shows"),
            ], mediaType: .podcast)
        let model = AddPodcastModel(service: AddPodcastPreviewService(), library: library)
        if let query {
            model.query = query
            model.submit()
        }
        return model
    }

    #Preview("Results") {
        @Previewable @State var model = addPodcastPreviewModel(query: "classic")
        NavigationStack {
            AddPodcastContent(model: model) { _ in }
                .navigationTitle(Text(verbatim: L10n.string("HeaderAddPodcast")))
        }
        .environment(\.serverID, UUID())
    }

    #Preview("Prompt") {
        @Previewable @State var model = addPodcastPreviewModel()
        NavigationStack {
            AddPodcastContent(model: model) { _ in }
                .navigationTitle(Text(verbatim: L10n.string("HeaderAddPodcast")))
        }
    }

    #Preview("No results, dark, largest text") {
        @Previewable @State var model = addPodcastPreviewModel(query: "nothing")
        NavigationStack {
            AddPodcastContent(model: model) { _ in }
                .navigationTitle(Text(verbatim: L10n.string("HeaderAddPodcast")))
        }
        .environment(\.dynamicTypeSize, .accessibility5)
        .preferredColorScheme(.dark)
    }

    #Preview("Search failed") {
        @Previewable @State var model = addPodcastPreviewModel(query: "fail")
        NavigationStack {
            AddPodcastContent(model: model) { _ in }
                .navigationTitle(Text(verbatim: L10n.string("HeaderAddPodcast")))
        }
    }
#endif

#Preview("Signed out") {
    NavigationStack { AddPodcastView() }
}
