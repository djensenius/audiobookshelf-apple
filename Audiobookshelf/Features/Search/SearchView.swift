import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The Search tab (legacy `pages/search.vue`): searches the router's current library as the user
/// types, in sections of books, podcasts, episodes, series, authors, narrators and tags.
///
/// The model belongs to one account and library (ADR 0004): ``SearchSession`` makes it with the
/// account's services (`LibraryStore.makeServices()`) and replaces it when the store, its
/// account or the router's library changes, keeping the query across a library switch. Its recent
/// searches are kept per account and library in `AppSettings`. Signed out, the screen shows the
/// signed-out state.
struct SearchView: View {
    @Environment(\.libraryStore) private var store
    @Environment(Router.self) private var router: Router?
    @Environment(AppSettings.self) private var settings: AppSettings?
    @State private var session = SearchSession()

    private var key: SearchSession.Key? {
        guard let store, let connectionKey = store.connectionKey, let libraryID = router?.libraryID else { return nil }
        return SearchSession.Key(store: ObjectIdentifier(store), connectionKey: connectionKey, libraryID: libraryID)
    }

    var body: some View {
        Group {
            if let model = session.model, session.key == key {
                SearchScreen(model: model)
            } else {
                SearchContent(
                    state: .placeholder(
                        canSearch: store?.connectionKey != nil && !(session.key == key && session.isUnavailable),
                        libraryID: router?.libraryID))
            }
        }
        .navigationTitle(Text(verbatim: L10n.string("ButtonSearch")))
        .task(id: key) {
            session.adopt(key) { key in
                store.flatMap { SearchSession.makeModel(for: key, store: $0, settings: settings) }
            }
            session.runPendingQuery(from: router)
        }
        .onChange(of: router?.pendingSearchQuery) {
            session.runPendingQuery(from: router)
        }
    }

}

/// Search while signed in with a library: the search field bound to the model, focused when the
/// router asks (Cmd+F, ``SearchCommands``).
private struct SearchScreen: View {
    let model: SearchModel
    @Environment(Router.self) private var router: Router?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        SearchContent(
            state: SearchScreenState.resolve(model), sections: model.results.sections,
            recentSearches: model.recentSearches, open: { SearchPresentation.open($0, in: router) },
            search: { search($0) }, clearRecentSearches: { model.clearRecentSearches() }, retry: { model.searchNow() }
        )
        .searchable(
            text: Binding(get: { model.query }, set: { model.setQuery($0) }),
            prompt: Text(verbatim: L10n.string("ButtonSearch"))
        )
        .searchFocused($isSearchFocused)
        .onSubmit(of: .search) { model.submit() }
        // Also on appear: the request usually selected this tab, so it predates the screen.
        .onChange(of: router?.isSearchFocusRequested, initial: true) { _, isRequested in
            guard isRequested == true else { return }
            router?.clearSearchFocusRequest()
            // After this update, so a field that is just being built takes the focus.
            Task { isSearchFocused = true }
        }
    }

    /// Searches for `query` at once, as from a recent search.
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
            ErrorStateView(title: L10n.string("MessageSearchLibraryFailed"), retry: retry)
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
                    Text(verbatim: L10n.string("HeaderSearchRecents"))
                    Spacer()
                    Button(action: clear) {
                        Text(verbatim: L10n.string("ButtonSearchClearRecents"))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text(verbatim: L10n.string("LabelSearchClearRecentsAccessibility")))
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
