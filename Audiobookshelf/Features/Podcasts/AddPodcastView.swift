import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// Add podcast (legacy `pages/bookshelf/add-podcast.vue`) for admins on a podcast library, with one model per account
/// and library. `onCreated` gets the new item's ID; by default it's pushed on the selected tab's stack.
struct AddPodcastView: View {
    var onCreated: ((String) -> Void)?
    @Environment(AccountManager.self) private var accounts: AccountManager?
    @Environment(\.libraryStore) private var store
    @Environment(Router.self) private var router: Router?
    @State private var built: (key: AddPodcastAccess.Key, model: AddPodcastModel)?

    init(onCreated: ((String) -> Void)? = nil) {
        self.onCreated = onCreated
    }

    var body: some View {
        let (access, library) = AddPodcastPresentation.access(accounts: accounts, store: store, router: router)
        Group {
            switch access {
            case .notAllowed:
                ErrorStateView(title: L10n.string("MessageAddPodcastNotAllowed"), systemImage: "lock")
            case .notPodcastLibrary:
                ErrorStateView(
                    title: L10n.string(AddPodcastPresentation.messages.empty),
                    systemImage: AppTab.addPodcast.systemImage)
            case .ready(let key):
                if let built, built.key == key {
                    // Captures the environment's objects: the create can finish after this view has changed.
                    AddPodcastContent(model: built.model) { [accounts, store, router, onCreated] itemID in
                        Self.open(
                            itemID, createdFor: key, accounts: accounts, store: store, router: router,
                            onCreated: onCreated)
                    }
                } else {
                    LoadingView()
                }
            case .waiting:
                BrowsePlaceholder(libraryID: library?.id, messages: AddPodcastPresentation.messages)
            }
        }
        .navigationTitle(Text(verbatim: L10n.string("HeaderAddPodcast")))
        .task(id: access) {
            guard case .ready(let key) = access, built?.key != key, let library else { return }
            let service = CurrentAddPodcastService { [weak accounts] in
                guard accounts?.activeConnection?.id == key.connectionID, let client = accounts?.client else {
                    throw CancellationError()
                }
                return client
            }
            built = (key, AddPodcastModel(service: service, library: library))
        }
        // A refresh keeps the model, and any open form, and only updates the folders and search region.
        .onChange(of: library) { _, library in
            if let library { built?.model.update(library: library) }
        }
    }

    /// Opens the podcast created for `key`, unless the account or library has changed since.
    private static func open(
        _ itemID: String, createdFor key: AddPodcastAccess.Key, accounts: AccountManager?, store: LibraryStore?,
        router: Router?, onCreated: ((String) -> Void)?
    ) {
        let (access, _) = AddPodcastPresentation.access(accounts: accounts, store: store, router: router)
        guard access.canOpen(createdFor: key) else { return }
        if let onCreated {
            onCreated(itemID)
        } else {
            BrowsePresentation.open(.item(id: itemID), in: router)
        }
    }
}

/// The search field, results and new-podcast sheet of one model; previews give it a fixture service.
struct AddPodcastContent: View {
    @Bindable var model: AddPodcastModel
    let onCreated: (String) -> Void
    @Environment(\.serverID) private var serverID
    /// The lookup error shown, kept while the alert is dismissed so its title doesn't go blank.
    @State private var shownLookupError: AddPodcastLookupError?
    @State private var showsLookupError = false

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
        .onChange(of: model.lookupError) { _, error in
            guard let error else { return }
            shownLookupError = error
            showsLookupError = true
            model.clearLookupError()
        }
        .onChange(of: model.searchError != nil) { _, failed in
            if failed { announce("MessagePodcastSearchFailed") }
        }
        .onChange(of: model.isLookingUpFeed) { _, started in
            if started { announce("MessageLoading") }
        }
        .alert(
            Text(verbatim: shownLookupError.map(Self.message) ?? ""), isPresented: $showsLookupError,
            presenting: shownLookupError
        ) { _ in
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

    private func announce(_ key: String) {
        AccessibilityNotification.Announcement(L10n.string(key)).post()
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
                key: AddPodcastPresentation.coverKey(url: result.cover, serverID: serverID),
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
    static let messages = BrowseMessages(
        failed: "MessageLibraryItemsLoadFailed", empty: "MessageAddPodcastNotPodcastLibrary",
        systemImage: AppTab.addPodcast.systemImage)

    /// What the screen may show, and the router's library from the store.
    @MainActor
    static func access(accounts: AccountManager?, store: LibraryStore?, router: Router?) -> (AddPodcastAccess, Library?)
    {
        let library = router?.libraryID.flatMap { id in store?.libraries.first { $0.id == id } }
        let access = AddPodcastAccess.resolve(
            user: accounts?.authorization?.user, connectionID: accounts?.activeConnection?.id,
            storeConnectionID: store?.connectionKey?.connectionID, library: library)
        return (access, library)
    }

    /// Artwork at `url`, under a fixed ID so feed URLs (which may hold private tokens) stay out of cache names.
    static func coverKey(url: String?, serverID: UUID?) -> ImageKey? {
        guard let url, let externalURL = URL(string: url), let serverID else { return nil }
        return CoverRef(entityID: "add-podcast", externalURL: externalURL).key(serverID: serverID)
    }
}

#if DEBUG
    /// Two shows, none for "nothing"; "fail" fails searches and creates.
    struct AddPodcastPreviewService: AddPodcastService {
        func searchPodcastDirectory(term: String, country: String?) async throws -> [PodcastDirectoryResult] {
            if term == "nothing" { return [] }
            if term == "fail" { throw APIError.notFound }
            return [
                PodcastDirectoryResult(
                    itunesID: "1", title: "Classic Tales", artistName: "B. J. Harrison", genres: ["Arts", "Books"],
                    trackCount: 812, feedURL: "https://feeds.example.com/classic-tales.xml"),
                PodcastDirectoryResult(
                    itunesID: "2", title: "Night Shift Mysteries: A title long enough to wrap", explicit: true),
            ]
        }

        func podcastFeed(rssFeed: String) async throws -> PodcastFeed {
            PodcastFeed(
                metadata: PodcastFeedMetadata(title: "Classic Tales", author: "B. J. Harrison", feedURL: rssFeed),
                episodes: [PodcastFeedEpisode(title: "The Speckled Band")], numEpisodes: 812)
        }

        func createPodcast(_ request: NewPodcastRequest) async throws -> ABSCore.LibraryItem {
            if request.media.metadata.title.localizedCaseInsensitiveContains("fail") {
                throw APIError.http(status: 400, message: "Podcast already exists")
            }
            return ABSCore.LibraryItem(id: "li_new", libraryId: request.libraryID, mediaType: .podcast)
        }
    }

    /// Search results for `query`, in a podcast library with one folder.
    private struct AddPodcastPreview: View {
        @State private var model = AddPodcastModel(
            service: AddPodcastPreviewService(),
            library: Library(
                id: SampleLibrary.libraryID, name: "Podcasts",
                folders: [LibraryFolder(id: "f1", fullPath: "/podcasts")],
                mediaType: .podcast))
        var query: String?

        var body: some View {
            NavigationStack {
                AddPodcastContent(model: model) { _ in }
                    .navigationTitle(Text(verbatim: L10n.string("HeaderAddPodcast")))
            }
            .task {
                model.query = query ?? ""
                model.submit()
            }
        }
    }

    #Preview("Results") { AddPodcastPreview(query: "classic").environment(\.serverID, UUID()) }
    #Preview("Prompt") { AddPodcastPreview() }
    #Preview("Search failed") { AddPodcastPreview(query: "fail") }
    #Preview("No results, dark, largest text") {
        AddPodcastPreview(query: "nothing").environment(\.dynamicTypeSize, .accessibility5).preferredColorScheme(.dark)
    }
#endif
