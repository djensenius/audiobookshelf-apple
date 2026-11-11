import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The Search tab (legacy `pages/search.vue`): searches the router's current library as the user
/// types, in sections of books, podcasts, episodes, series, authors, narrators and tags.
///
/// The model belongs to one account and library (ADR 0004): it is built with the account's
/// ``SearchService`` (from ``SearchServiceSource``) and rebuilt when the store, its account or the
/// router's library changes. Its recent searches are kept per account and library in the
/// settings' defaults. Signed out, or without a service, the screen shows the signed-out state.
struct SearchView: View {
    @Environment(\.libraryStore) private var store
    @Environment(Router.self) private var router: Router?
    @Environment(AppSettings.self) private var settings: AppSettings?
    @State private var host: SearchHost?
    /// The store's account has no ``SearchService``.
    @State private var isUnavailable = false

    private var key: SearchHost.Key? {
        guard let store, let connectionKey = store.connectionKey, let libraryID = router?.libraryID else { return nil }
        return SearchHost.Key(store: ObjectIdentifier(store), connectionKey: connectionKey, libraryID: libraryID)
    }

    var body: some View {
        Group {
            if let host, host.key == key {
                SearchScreen(model: host.model)
            } else {
                SearchContent(
                    state: .placeholder(
                        canSearch: store?.connectionKey != nil && !isUnavailable, libraryID: router?.libraryID))
            }
        }
        .navigationTitle(Text(verbatim: L10n.string("ButtonSearch")))
        .task(id: key) {
            guard let key, let store else {
                host = nil
                isUnavailable = false
                return
            }
            guard host?.key != key else { return }
            guard let service = SearchServiceSource.service(from: store) else {
                host = nil
                isUnavailable = true
                return
            }
            isUnavailable = false
            let recents = settings.map { SearchRecentsStore(defaults: $0.defaults) }
            host = SearchHost(
                key: key,
                model: SearchModel(
                    service: service, libraryID: key.libraryID,
                    recentSearches: recents?.recentSearches(connectionKey: key.connectionKey, libraryID: key.libraryID)
                        ?? [],
                    persistRecents: recents?.persist(connectionKey: key.connectionKey, libraryID: key.libraryID)))
        }
    }
}

/// The model for one store, account and library.
private struct SearchHost {
    struct Key: Hashable {
        let store: ObjectIdentifier
        let connectionKey: LibraryConnectionKey
        let libraryID: String
    }

    let key: Key
    let model: SearchModel
}

/// Search while signed in with a library: the search field bound to the model, Cmd+F to focus
/// it on a Mac, and a `search?q=` link's query.
private struct SearchScreen: View {
    let model: SearchModel
    @Environment(Router.self) private var router: Router?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        SearchContent(
            state: SearchScreenState.resolve(model), sections: model.results.sections,
            recentSearches: model.recentSearches, open: { SearchPresentation.open($0, in: router) },
            search: { search($0) }, clearRecentSearches: { model.clearRecentSearches() }, retry: { model.submit() }
        )
        .searchable(
            text: Binding(get: { model.query }, set: { model.setQuery($0) }),
            prompt: Text(verbatim: L10n.string("ButtonSearch"))
        )
        .searchFocused($isSearchFocused)
        .onSubmit(of: .search) { model.submit() }
        #if os(macOS)
            .background {
                // Cmd+F focuses the search field. Invisible: the field is already in the toolbar.
                Button {
                    isSearchFocused = true
                } label: {
                    Text(verbatim: L10n.string("ButtonSearch"))
                }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
            }
        #endif
        .onChange(of: router?.pendingSearchQuery, initial: true) { _, query in
            guard let query else { return }
            router?.pendingSearchQuery = nil
            search(query)
        }
    }

    /// Searches for `query` at once, as from a recent search or a link.
    private func search(_ query: String) {
        model.setQuery(query)
        model.submit()
    }
}

/// Search for one ``SearchScreenState``. Has no model, so previews show every state with fixtures.
struct SearchContent: View {
    let state: SearchScreenState
    var sections: [SearchResultSection] = []
    var recentSearches: [String] = []
    var open: (Route) -> Void = { _ in }
    /// Runs a recent search again.
    var search: (String) -> Void = { _ in }
    var clearRecentSearches: () -> Void = {}
    var retry: () -> Void = {}

    var body: some View {
        switch state {
        case .signedOut:
            SearchMessageView(
                title: L10n.string("MessageAudiobookshelfServerNotConnected"), systemImage: "icloud.slash")
        case .noLibrary:
            SearchMessageView(title: L10n.string("MessageBookshelfEmpty"), systemImage: "books.vertical")
        case .loading, .searching:
            LoadingView(message: L10n.string("MessageFetching"))
        case .idle:
            if recentSearches.isEmpty {
                SearchMessageView(
                    title: L10n.string("ButtonSearch"), message: L10n.string("MessageSearchLibraryPrompt"),
                    systemImage: "magnifyingglass")
            } else {
                SearchRecentsView(recentSearches: recentSearches, search: search, clear: clearRecentSearches)
            }
        case .noResults:
            SearchMessageView(title: L10n.string("MessageNoItemsFound"), systemImage: "magnifyingglass")
        case .failed:
            ErrorStateView(title: L10n.string("MessageSearchFailed"), retry: retry)
        case .results(let isSearching, let failed):
            SearchResultsView(
                sections: sections, isSearching: isSearching, failed: failed, open: open, retry: retry)
        }
    }
}

/// The recent searches, most recent first; a tap searches again.
private struct SearchRecentsView: View {
    let recentSearches: [String]
    let search: (String) -> Void
    let clear: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(recentSearches, id: \.self) { query in
                    Button {
                        search(query)
                    } label: {
                        Label {
                            Text(verbatim: query)
                                .foregroundStyle(ABSColor.foreground)
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(ABSColor.mutedForeground)
                                .accessibilityHidden(true)
                        }
                    }
                }
            } header: {
                HStack {
                    Text(verbatim: L10n.string("HeaderRecentSearches"))
                    Spacer()
                    Button(action: clear) {
                        Text(verbatim: L10n.string("ButtonClear"))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text(verbatim: L10n.string("ButtonClearRecentSearches")))
                }
            }
        }
    }
}

/// A full-screen message.
private struct SearchMessageView: View {
    let title: String
    var message: String?
    let systemImage: String

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
        } description: {
            if let message {
                Text(verbatim: message)
            }
        }
    }
}

#if DEBUG
    #Preview("Results") {
        NavigationStack {
            SearchContent(
                state: .results(isSearching: false, failed: false), sections: SearchPreviewData.sections
            )
            .navigationTitle(Text(verbatim: L10n.string("ButtonSearch")))
        }
        .environment(\.serverID, UUID())
        .absBackground()
    }

    #Preview("Results, failed refresh, largest text") {
        NavigationStack {
            SearchContent(state: .results(isSearching: true, failed: true), sections: SearchPreviewData.sections)
        }
        .environment(\.dynamicTypeSize, .accessibility3)
        .absBackground()
    }
#endif

#Preview("Recent searches") {
    NavigationStack {
        SearchContent(state: .idle, recentSearches: ["Dune", "Jane Austen", "Barsoom"])
            .navigationTitle(Text(verbatim: L10n.string("ButtonSearch")))
    }
    .absBackground()
}

#Preview("No results") {
    NavigationStack {
        SearchContent(state: .noResults)
            .navigationTitle(Text(verbatim: L10n.string("ButtonSearch")))
    }
    .absBackground()
}

#Preview("Error") {
    NavigationStack {
        SearchContent(state: .failed)
            .navigationTitle(Text(verbatim: L10n.string("ButtonSearch")))
    }
    .absBackground()
}

#Preview("Signed out, dark") {
    NavigationStack { SearchView() }
        .absBackground()
        .preferredColorScheme(.dark)
}
